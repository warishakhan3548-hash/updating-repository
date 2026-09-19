// Offline conversational protocol checks: no Flutter, APK, network or API keys.
import 'dart:convert';
import 'dart:io';

import '../lib/domain/ai_configuration.dart';
import '../lib/domain/ai_conversation.dart';
import '../lib/domain/ai_protocol.dart';
import '../lib/domain/medicine.dart';
import '../lib/services/ai_provider_adapter.dart';

var checks = 0;
void check(bool result, String label) {
  checks++;
  if (!result) throw StateError(label);
}

void rejects(void Function() operation, String label) {
  var rejected = false;
  try {
    operation();
  } on FormatException {
    rejected = true;
  }
  check(rejected, label);
}

void main() {
  final today = DateTime.utc(2026, 9, 15);
  final medicine = Medicine.fromJson({
    'id': 'stock_existing',
    'name': 'Owner supplied medicine',
    'expiry': '2027-02',
    'quantity': 12,
  });
  final records = {medicine.id: medicine};
  final snapshot = PharmacyExport(
    revision: 7,
    records: records.values,
    today: today,
  );
  check(
    snapshot.prompt.contains('CONVERSATION IS THE DEFAULT'),
    'Chat default',
  );
  check(
    snapshot.prompt.contains('general knowledge'),
    'General questions allowed',
  );
  check(
    snapshot.prompt.contains('is not permission'),
    'No implicit end-of-chat writes',
  );
  check(
    !snapshot.prompt.contains('"actions":[]'),
    'No question-only JSON example',
  );
  check(snapshot.prompt.contains('okay, add it'), 'Contextual add instruction');
  check(
    snapshot.prompt.contains('never that they have already been saved'),
    'Honest review status',
  );
  check(snapshot.content.contains(medicine.id), 'Current stock facts included');

  for (final message in [
    'नमस्ते! बताइए, क्या जानना चाहते हैं?',
    'इस pack की expiry साफ़ नहीं दिख रही। उसकी साफ़ फोटो भेजेंगे?',
    'This estimate depends on the sales history available.',
    'Which of the two packs should I add?',
    'Okay, thanks!',
    'Here is a code example:\n```dart\nprint("hello");\n```',
    '{"schema":"example","value":42}',
  ]) {
    final response = AiConversationResponse.parse(message);
    check(
      response.reply == message && response.planJson == null,
      'Normal chat stays readable',
    );
  }

  Map<String, dynamic> envelope(List<Object?> actions) => {
    'schema': pharmacySchema,
    'requestId': snapshot.requestId,
    'baseRevision': snapshot.revision,
    'reply': 'आपके बदलाव review के लिए तैयार हैं।',
    'actions': actions,
  };
  for (final value in [
    {'reply': 'नमस्ते!'},
    {'reply': 'नमस्ते!', 'actions': []},
    {'reply': 'नमस्ते!', 'operations': []},
    {...envelope([]), 'reply': 'नमस्ते!'},
  ]) {
    for (final wrapped in [false, true]) {
      final json = jsonEncode(value);
      final response = AiConversationResponse.parse(
        wrapped ? '```json\n$json\n```' : json,
      );
      check(
        response.reply == 'नमस्ते!' && response.planJson == null,
        'Legacy empty actions become chat',
      );
    }
  }

  final add = envelope([
    {
      'op': 'add',
      'fields': {'name': 'Confirmed new item', 'expiry': '2028-01'},
    },
  ]);
  final addJson = jsonEncode(add);
  for (final text in [
    addJson,
    '\uFEFF$addJson',
    '```json\n$addJson\n```',
    'Changes prepared for review:\n```json\n$addJson\n```\nReview in Aaris.',
  ]) {
    final response = AiConversationResponse.parse(text);
    check(
      response.planJson != null && response.reply.isEmpty,
      'Action data goes to review',
    );
    final plan = parseAiPlan(response.planJson!, records, 7, {}, today);
    check(
      plan.changes.single.after.name == 'Confirmed new item',
      'Confirmed name carried through',
    );
    check(
      plan.changes.single.after.quantity == null,
      'Unknown quantity stays unknown',
    );
    check(
      plan.requestId == snapshot.requestId && plan.baseRevision == 7,
      'Snapshot identity retained',
    );
  }
  check(
    records.length == 1 && medicine.quantity == 12,
    'Parsing does not save inventory',
  );
  final update = AiConversationResponse.parse(
    jsonEncode(
      envelope([
        {
          'op': 'update',
          'id': medicine.id,
          'fields': {'expiry': '2028-04'},
        },
      ]),
    ),
  );
  final updatePlan = parseAiPlan(update.planJson!, records, 7, {}, today);
  check(
    updatePlan.changes.single.before?.id == medicine.id,
    'Update targets exact existing row',
  );
  check(
    updatePlan.changes.single.after.quantity == 12,
    'Unchanged facts preserved',
  );

  for (final invalid in [
    '',
    '{',
    '{"reply":"unfinished',
    '[$addJson]',
    '```json\n$addJson',
    '$addJson\n$addJson',
    '```json\n$addJson\n```\n```json\n$addJson\n```',
    '$addJson\n```json\n$addJson\n```',
    '{"schema":"other","reply":"x","actions":[]}',
    '{"reply":1,"actions":[]}',
  ]) {
    rejects(
      () => AiConversationResponse.parse(invalid),
      'Malformed/ambiguous response rejected',
    );
  }
  for (final invalid in [
    {...add, 'baseRevision': 6},
    {...add, 'requestId': 'bad'},
    {...add, 'path': '/somewhere'},
    {...add, 'operations': []},
    envelope([
      {
        'op': 'update',
        'id': 'guessed',
        'fields': {'quantity': 2},
      },
    ]),
    envelope([
      {
        'op': 'add',
        'fields': {'name': 'Item', 'status': 'safe'},
      },
    ]),
    {'reply': 'add it', 'actions': add['actions']},
  ]) {
    rejects(() {
      final response = AiConversationResponse.parse(jsonEncode(invalid));
      parseAiPlan(response.planJson!, records, 7, {}, today);
    }, 'Action validator cannot be bypassed by conversational parsing');
  }
  rejects(
    () => parseAiPlan(addJson, records, 7, {snapshot.requestId}, today),
    'Replay blocked',
  );
  try {
    parseAiPlan('{"reply":"PRIVATE_SOURCE', records, 7, {}, today);
    throw StateError('Malformed protocol accepted');
  } on FormatException catch (error) {
    check(
      !error.toString().contains('PRIVATE_SOURCE'),
      'Malformed JSON does not leak in error bubble',
    );
  }

  for (final output in [
    addJson,
    'Prepared:\n$addJson',
    'Prepared:\n```json\n$addJson\n```',
  ]) {
    var leaked = false;
    for (var end = 1; end <= output.length; end++) {
      final visible = aiConversationPreview(output.substring(0, end));
      leaked |=
          visible.contains('{') ||
          visible.contains('`') ||
          visible.contains('requestId');
    }
    check(!leaked, 'Chunk boundaries cannot flash action JSON');
  }
  check(
    aiConversationPreview('नमस्ते!') == 'नमस्ते!',
    'Normal text streams immediately',
  );

  // Typed chat routing now belongs to AiScreen rather than this response
  // parser. The response layer must stay free of App Brain intent coupling so
  // words like add/edit/delete can reach the configured AI unchanged.
  final conversationSource = File(
    'lib/domain/ai_conversation.dart',
  ).readAsStringSync();
  check(
    !conversationSource.contains('isAiConversationFollowUp') &&
        !conversationSource.contains("import 'app_brain.dart';"),
    'Conversation parser is independent from deterministic command intents',
  );

  for (final provider in ['Gemini', 'OpenAI', 'Anthropic', 'xAI', 'Groq']) {
    final stored = AiConfiguration(
      provider: provider,
      model: 'test-model',
      key: 'fake-key',
      jsonModeEnabled: true,
      responseTimeoutSeconds: 150,
    );
    final chat = stored.forConversation;
    check(
      stored.useJsonMode && !chat.useJsonMode,
      'Chat does not overwrite stored JSON preference',
    );
    check(
      chat.key == stored.key &&
          chat.uri == stored.uri &&
          chat.responseTimeout == stored.responseTimeout,
      'Route/credential/deadline retained',
    );
    for (final stream in [true, false]) {
      final request = AiProviderAdapter.forConfiguration(chat).request(
        config: chat,
        system: snapshot.prompt,
        user: 'What is this medicine used for?',
        stream: stream,
      );
      final body = jsonDecode(request.body) as Map;
      check(
        !body.containsKey('response_format'),
        '$provider chat allows prose',
      );
      check(
        (body['generationConfig'] as Map?)?['responseMimeType'] == null,
        '$provider does not force JSON MIME',
      );
      check(
        !request.followRedirects &&
            !request.url.toString().contains(stored.key),
        'Credential boundary retained',
      );
    }
    if (provider != 'Anthropic') {
      final structured = AiProviderAdapter.forConfiguration(stored).request(
        config: stored,
        system: 'Return structured scan evidence.',
        user: 'OCR facts',
        stream: false,
      );
      final body = jsonDecode(structured.body) as Map;
      check(
        provider == 'Gemini'
            ? body['generationConfig']['responseMimeType'] == 'application/json'
            : body['response_format']['type'] == 'json_object',
        'Structured scan preference retained',
      );
    }
  }
  stdout.writeln('AI conversation contract: $checks passed.');
}
