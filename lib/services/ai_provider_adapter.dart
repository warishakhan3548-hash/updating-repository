import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/ai_configuration.dart';

/// Protocol-only boundary shared by cloud chat and evidence-only cloud scans.
/// No inventory access, credentials persistence, retry, or model lease ownership.
abstract class AiProviderAdapter {
  const AiProviderAdapter();

  static AiProviderAdapter forConfiguration(AiConfiguration config) {
    final adapter = switch (config.protocol) {
        AiProviderProtocol.gemini => const GeminiProviderAdapter(),
        AiProviderProtocol.chatCompletions =>
          const ChatCompletionsProviderAdapter(),
        AiProviderProtocol.anthropicMessages =>
          const AnthropicMessagesProviderAdapter(),
    };
    if (config.useJsonMode && !adapter.supportsJsonMode) {
      throw AiProviderFailure(AiProviderFailureKind.unsupportedCapability);
    }
    return adapter;
  }

  bool get supportsJsonMode;
  bool get acceptsUnlabelledStream => false;
  bool get canNegotiateStreaming => false;

  http.Request request({
    required AiConfiguration config,
    required String system,
    required String user,
    required bool stream,
    int? maxOutputTokens,
  });

  String text(Map<String, dynamic> envelope);
  String delta(Map<String, dynamic> event);
  bool terminal(Map<String, dynamic> event);

  String decode(List<int> bytes) {
    Object? value;
    try {
      value = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('Provider returned incompatible JSON.');
    }
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Provider returned incompatible JSON.');
    }
    final result = text(value);
    if (result.trim().isEmpty) {
      throw const FormatException('Provider returned no usable text.');
    }
    return result;
  }

  http.Request post(
    Uri target,
    Map<String, Object?> body,
    Map<String, String> authentication, {
    required bool stream,
  }) => http.Request('POST', target)
    ..followRedirects = false
    ..headers.addAll({
      'Content-Type': 'application/json',
      'Accept': stream ? 'text/event-stream' : 'application/json',
      ...authentication,
    })
    ..body = jsonEncode(body);
}

String _textParts(Object? value) {
  if (value is String) return value;
  if (value is! List) return '';
  return value.whereType<Map>()
      .where((part) => part['thought'] != true &&
          (part['type'] == null || part['type'] == 'text'))
      .map((part) => part['text']).whereType<String>().join();
}

Map? _firstMap(Object? value) =>
    value is List && value.isNotEmpty && value.first is Map
        ? value.first as Map
        : null;

class GeminiProviderAdapter extends AiProviderAdapter {
  const GeminiProviderAdapter();
  @override
  bool get supportsJsonMode => true;

  @override
  http.Request request({
    required AiConfiguration config,
    required String system,
    required String user,
    required bool stream,
    int? maxOutputTokens,
  }) {
    final endpoint = config.uri;
    final target = stream
        ? endpoint.replace(
            path: endpoint.path.replaceFirst(
              ':generateContent', ':streamGenerateContent',
            ),
            queryParameters: const {'alt': 'sse'},
          )
        : endpoint;
    return post(target, {
      'system_instruction': {'parts': [{'text': system}]},
      'contents': [{'role': 'user', 'parts': [{'text': user}]}],
      'generationConfig': {
        if (config.useJsonMode) 'responseMimeType': 'application/json',
        if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
      },
    }, {'x-goog-api-key': config.key}, stream: stream);
  }

  @override
  String text(Map<String, dynamic> envelope) {
    final first = _firstMap(envelope['candidates']);
    final content = first?['content'];
    return content is Map ? _textParts(content['parts']) : '';
  }
  @override
  String delta(Map<String, dynamic> event) => text(event);
  @override
  bool terminal(Map<String, dynamic> event) =>
      _firstMap(event['candidates'])?['finishReason'] != null;
}

class ChatCompletionsProviderAdapter extends AiProviderAdapter {
  const ChatCompletionsProviderAdapter();
  @override
  bool get supportsJsonMode => true;
  @override
  bool get acceptsUnlabelledStream => true;
  @override
  bool get canNegotiateStreaming => true;

  @override
  http.Request request({
    required AiConfiguration config,
    required String system,
    required String user,
    required bool stream,
    int? maxOutputTokens,
  }) => post(config.uri, {
    'model': config.model,
    'messages': [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ],
    if (stream) 'stream': true,
    if (config.useJsonMode) 'response_format': {'type': 'json_object'},
    // Compatible servers disagree on token-limit/temperature parameter names.
    // Keep the legacy minimal request unless a concrete capability is selected.
  }, {'Authorization': 'Bearer ${config.key}'}, stream: stream);

  @override
  String text(Map<String, dynamic> envelope) {
    final first = _firstMap(envelope['choices']);
    final message = first?['message'];
    return message is Map
        ? _textParts(message['content'])
        : _textParts(first?['text']);
  }
  @override
  String delta(Map<String, dynamic> event) {
    final first = _firstMap(event['choices']);
    final change = first?['delta'];
    if (change is Map && change['content'] != null) {
      return _textParts(change['content']);
    }
    final message = first?['message'];
    if (message is Map && message['content'] != null) {
      return _textParts(message['content']);
    }
    final choiceText = _textParts(first?['text']);
    if (choiceText.isNotEmpty) return choiceText;

    // Preserve supported legacy gateways that emit top-level text deltas.
    // Typed reasoning/tool events are excluded from assistant output.
    final type = event['type'];
    if (type != null && type != 'text_delta' &&
        type != 'response.output_text.delta') return '';
    final topDelta = event['delta'];
    if (topDelta is String) return topDelta;
    if (topDelta is Map && topDelta['thought'] != true &&
        (topDelta['type'] == null || topDelta['type'] == 'text_delta')) {
      return _textParts(topDelta['text']);
    }
    return _textParts(event['output_text']);
  }

  @override
  bool terminal(Map<String, dynamic> event) =>
      _firstMap(event['choices'])?['finish_reason'] != null;
}

class AnthropicMessagesProviderAdapter extends AiProviderAdapter {
  const AnthropicMessagesProviderAdapter();
  // JSON schema features are model/version dependent. Prompt-only structured
  // extraction is supported; the domain validator always remains mandatory.
  @override
  bool get supportsJsonMode => false;

  @override
  http.Request request({
    required AiConfiguration config,
    required String system,
    required String user,
    required bool stream,
    int? maxOutputTokens,
  }) => post(config.uri, {
    'model': config.model,
    'system': system,
    'messages': [{'role': 'user', 'content': user}],
    'max_tokens': maxOutputTokens ?? 4096,
    if (stream) 'stream': true,
  }, {
    'x-api-key': config.key,
    'anthropic-version': '2023-06-01',
  }, stream: stream);

  @override
  String text(Map<String, dynamic> envelope) =>
      _textParts(envelope['content']);
  @override
  String delta(Map<String, dynamic> event) {
    if (event['type'] == 'content_block_start') {
      final block = event['content_block'];
      return block is Map && block['type'] == 'text'
          ? _textParts(block['text']) : '';
    }
    final value = event['delta'];
    return event['type'] == 'content_block_delta' &&
            value is Map && value['type'] == 'text_delta'
        ? _textParts(value['text']) : '';
  }
  @override
  bool terminal(Map<String, dynamic> event) => event['type'] == 'message_stop';
}

/// Error categories are stable across protocols; provider bodies are never
/// forwarded as error messages because they may echo prompts or credentials.
enum AiProviderFailureKind {
  authentication, unavailable, timeout, rateLimited,
  unsupportedCapability, malformedResponse, network, modelUnavailable, cancelled,
}

class AiProviderFailure extends StateError {
  AiProviderFailure(this.kind, {this.statusCode})
      : super(_description(kind, statusCode));
  final AiProviderFailureKind kind;
  final int? statusCode;

  factory AiProviderFailure.http(int status) => AiProviderFailure(
    switch (status) {
      401 || 403 => AiProviderFailureKind.authentication,
      404 => AiProviderFailureKind.modelUnavailable,
      408 => AiProviderFailureKind.timeout,
      429 => AiProviderFailureKind.rateLimited,
      400 || 405 || 415 || 422 => AiProviderFailureKind.unsupportedCapability,
      _ => AiProviderFailureKind.unavailable,
    },
    statusCode: status,
  );

  static String _description(AiProviderFailureKind kind, int? status) {
    final hint = switch (kind) {
      AiProviderFailureKind.authentication => 'Check the API key and access.',
      AiProviderFailureKind.rateLimited => 'Provider limit reached. Retry later.',
      AiProviderFailureKind.modelUnavailable => 'Check the model and endpoint.',
      AiProviderFailureKind.unsupportedCapability =>
        'Check the endpoint and configured streaming/JSON capabilities.',
      AiProviderFailureKind.timeout => 'The provider response deadline expired.',
      AiProviderFailureKind.malformedResponse =>
        'The provider returned an incompatible response.',
      AiProviderFailureKind.network => 'The provider connection was interrupted.',
      AiProviderFailureKind.cancelled => 'AI request cancelled.',
      AiProviderFailureKind.unavailable => 'The provider is unavailable.',
    };
    return 'AI provider${status == null ? '' : ' returned HTTP $status'}. '
        '$hint No inventory changes were made.';
  }
}
