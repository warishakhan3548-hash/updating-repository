import 'dart:convert';

import 'ai_protocol.dart';

/// The conversational boundary does not authorize or repair inventory actions.
/// Every non-empty plan still goes through parseAiPlan and the save preview.
class AiConversationResponse {
  const AiConversationResponse._({this.reply = '', this.planJson});

  final String reply;
  final String? planJson;

  factory AiConversationResponse.parse(String input) {
    final text = input.trim().replaceFirst('\uFEFF', '').trim();
    if (text.isEmpty || text.length > 1000000) {
      throw const FormatException('The AI response is empty or too large.');
    }
    var candidate = text;
    // Some models put their single action object in a fenced block with a
    // short explanation. Accept that wrapper, never merge multiple proposals.
    final fences = RegExp(
      r'```(?:json|[a-z0-9.+-]+\+json)?[ \t]*\r?\n([\s\S]*?)```',
      caseSensitive: false,
    ).allMatches(text).toList();
    final protocolFences = fences
        .where((match) => containsAiConversationJson(match.group(1)!))
        .toList();
    if (protocolFences.isNotEmpty) {
      if (fences.length != 1 || protocolFences.length != 1) {
        throw _invalidResponse;
      }
      final fence = protocolFences.single;
      final outside =
          text.substring(0, fence.start) + text.substring(fence.end);
      if (containsAiConversationJson(outside)) throw _invalidResponse;
      candidate = fence.group(1)!.trim();
    }

    Object? decoded;
    try {
      decoded = jsonDecode(candidate);
    } on FormatException {
      if (containsAiConversationJson(text) || text.startsWith('{')) {
        throw _invalidResponse;
      }
      return AiConversationResponse._(reply: text);
    }
    if (decoded is! Map<String, dynamic> && containsAiConversationJson(text)) {
      throw _invalidResponse;
    }
    if (decoded is! Map<String, dynamic> ||
        (decoded['schema'] != pharmacySchema &&
            !decoded.keys.any(
              (key) => const {'reply', 'actions', 'operations'}.contains(key),
            ))) {
      return AiConversationResponse._(reply: text);
    }
    final schema = decoded['schema'];
    if (schema != null && schema != pharmacySchema) throw _invalidResponse;

    final actions = decoded['actions'] ?? decoded['operations'];
    final legacyReplyOnly = decoded.length == 1 && decoded.containsKey('reply');
    final readOnly =
        actions is List &&
        actions.isEmpty &&
        !(decoded.containsKey('actions') && decoded.containsKey('operations'));
    const envelopeKeys = {
      'schema',
      'requestId',
      'baseRevision',
      'scope',
      'reply',
      'actions',
      'operations',
    };
    if ((legacyReplyOnly || readOnly) &&
        decoded.keys.every(envelopeKeys.contains) &&
        (decoded['scope'] == null || decoded['scope'] == 'pharmacy')) {
      final reply = decoded['reply'];
      if (reply is! String || reply.trim().isEmpty || reply.length > 12000) {
        throw _invalidResponse;
      }
      // Old cloud/local prompts may still return empty action envelopes.
      // Display their explanation without a zero-change review or raw JSON.
      return AiConversationResponse._(reply: reply.trim());
    }
    return AiConversationResponse._(planJson: candidate);
  }
}

const _invalidResponse = FormatException(
  'The AI returned incomplete or ambiguous change data. Ask it for one complete pharmacy action object. Nothing was changed.',
);

bool containsAiConversationJson(String text) => RegExp(
  r'"(?:reply|actions|operations)"\s*:|"schema"\s*:\s*"aaris\.pharmacy\.v1',
).hasMatch(text);

/// Hold possible JSON/code until the complete response can be classified, even
/// when the opening marker arrives after prose or is split across stream chunks.
String aiConversationPreview(String text) {
  var end = text.length;
  for (final marker in ['{', '`']) {
    final position = text.indexOf(marker);
    if (position >= 0 && position < end) end = position;
  }
  return text.substring(0, end);
}
