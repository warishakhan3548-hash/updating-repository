import 'dart:convert';

import 'ai_provider_catalog.dart';
export 'ai_provider_catalog.dart';

class AiConfiguration {
  const AiConfiguration({
    this.provider = 'Gemini',
    this.model = '',
    this.endpoint = '',
    this.modelsEndpoint = '',
    this.key = '',
    this.localBrainEnabled = false,
    this.autoSelectModel = false,
    this.streamingEnabled = true,
    this.jsonModeEnabled,
    this.responseTimeoutSeconds = 90,
  });
  final String provider, model, endpoint, modelsEndpoint, key;
  final bool localBrainEnabled, streamingEnabled, autoSelectModel;

  /// null preserves the legacy default: JSON mode for Gemini, prompt-only for
  /// compatible servers. This is configured capability, never inferred from a
  /// model's brand/name. Conversational requests opt out; structured scan
  /// requests retain this preference and their evidence validator.
  final bool? jsonModeEnabled;
  final int responseTimeoutSeconds;

  AiProviderDefinition get definition => AiProviderDefinition.forId(provider);
  AiProviderProtocol get protocol => definition.protocol;
  String get providerLabel => definition.label;

  bool get useJsonMode =>
      jsonModeEnabled ?? protocol == AiProviderProtocol.gemini;

  /// Conversation can return prose or an action envelope. Forcing JSON at the
  /// provider overrides that choice. Do not change the saved scan preference.
  AiConfiguration get forConversation => copyWith(jsonModeEnabled: false);

  Duration get responseTimeout {
    if (responseTimeoutSeconds < 10 || responseTimeoutSeconds > 180) {
      throw const FormatException(
        'AI response timeout must be 10–180 seconds.',
      );
    }
    return Duration(seconds: responseTimeoutSeconds);
  }

  AiConfiguration copyWith({
    String? provider,
    String? model,
    String? endpoint,
    String? modelsEndpoint,
    String? key,
    bool? localBrainEnabled,
    bool? autoSelectModel,
    bool? streamingEnabled,
    bool? jsonModeEnabled,
    int? responseTimeoutSeconds,
  }) => AiConfiguration(
    provider: provider ?? this.provider,
    model: model ?? this.model,
    endpoint: endpoint ?? this.endpoint,
    modelsEndpoint: modelsEndpoint ?? this.modelsEndpoint,
    key: key ?? this.key,
    localBrainEnabled: localBrainEnabled ?? this.localBrainEnabled,
    autoSelectModel: autoSelectModel ?? this.autoSelectModel,
    streamingEnabled: streamingEnabled ?? this.streamingEnabled,
    jsonModeEnabled: jsonModeEnabled ?? this.jsonModeEnabled,
    responseTimeoutSeconds:
        responseTimeoutSeconds ?? this.responseTimeoutSeconds,
  );

  // This envelope belongs exclusively in platform-backed secure storage. It must
  // never be included in inventory export, backup or diagnostics.
  Map<String, dynamic> toJson() => {
    'version': 2,
    'provider': definition.id,
    'model': model,
    'endpoint': endpoint,
    'modelsEndpoint': modelsEndpoint,
    'key': key,
    'localBrainEnabled': localBrainEnabled,
    'autoSelectModel': autoSelectModel,
    'streamingEnabled': streamingEnabled,
    'jsonModeEnabled': jsonModeEnabled,
    'responseTimeoutSeconds': responseTimeoutSeconds,
  };

  /// Decode only inside secure-storage readers. JSON parser exceptions can
  /// contain source excerpts, so never let one expose a saved credential in UI.
  factory AiConfiguration.fromStored(String? raw) {
    if (raw == null) return const AiConfiguration();
    if (raw.length > 64 * 1024) {
      throw const FormatException('Saved AI configuration is too large.');
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Saved AI configuration is invalid.');
      }
      return AiConfiguration.fromJson(value);
    } on FormatException {
      throw const FormatException(
        'Saved AI configuration is invalid. Reconnect the API in settings.',
      );
    }
  }

  factory AiConfiguration.fromJson(Map<String, dynamic> data) {
    String text(String name, String fallback, int limit) {
      final value = data[name];
      if (value == null) return fallback;
      if (value is! String || value.length > limit) {
        throw const FormatException('Saved AI configuration is invalid.');
      }
      return value;
    }

    bool boolean(String name, bool fallback) {
      final value = data[name];
      if (value == null) return fallback;
      if (value is! bool) {
        throw const FormatException('Saved AI capability is invalid.');
      }
      return value;
    }

    final version = data['version'];
    if (version != null && version != 1 && version != 2) {
      throw const FormatException(
        'Saved AI configuration version is unsupported.',
      );
    }
    final jsonMode = data['jsonModeEnabled'];
    final timeout = data['responseTimeoutSeconds'] ?? 90;
    if ((jsonMode != null && jsonMode is! bool) ||
        timeout is! int ||
        timeout < 10 ||
        timeout > 180) {
      throw const FormatException('Saved AI capabilities are invalid.');
    }
    final config = AiConfiguration(
      provider: AiProviderDefinition.forId(text('provider', 'Gemini', 80)).id,
      model: text('model', '', 200),
      endpoint: text('endpoint', '', 2048),
      modelsEndpoint: text('modelsEndpoint', '', 2048),
      key: text('key', '', 8192),
      localBrainEnabled: boolean('localBrainEnabled', false),
      autoSelectModel: boolean('autoSelectModel', false),
      streamingEnabled: boolean('streamingEnabled', true),
      jsonModeEnabled: jsonMode as bool?,
      responseTimeoutSeconds: timeout,
    );
    config.protocol;
    return config;
  }

  void validateCredential() {
    if (key.trim().isEmpty) throw const FormatException('Enter your API key.');
    if (key.length > 8192 || RegExp(r'[\x00-\x20\x7f]').hasMatch(key)) {
      throw const FormatException('API key contains invalid characters.');
    }
  }

  static bool validModelId(String id) =>
      id.isNotEmpty &&
      id.length <= 200 &&
      !RegExp(r'[\x00-\x20\x7f]').hasMatch(id);

  static Uri _https(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (raw.length > 2048 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Enter an HTTPS URL without credentials or query parameters.',
      );
    }
    return uri;
  }

  Uri get _customChatUri {
    final value = _https(endpoint);
    final path = value.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.isEmpty) return value.replace(path: '/v1/chat/completions');
    if (path.endsWith('/v1'))
      return value.replace(path: '$path/chat/completions');
    // Preserve existing full proxy endpoints exactly.
    return value;
  }

  /// No model ID is needed. Custom discovery stays on the inference origin;
  /// an API key is never probed against other companies.
  Uri get modelsUri {
    validateCredential();
    if (!definition.isCustom) {
      return Uri.parse('${definition.baseUrl}${definition.modelsPath}');
    }
    final chat = _customChatUri;
    if (modelsEndpoint.trim().isNotEmpty) {
      final models = _https(modelsEndpoint);
      if (models.origin != chat.origin) {
        throw const FormatException(
          'Models URL must use the same host and port as the chat URL.',
        );
      }
      return models;
    }
    final path = chat.path.replaceFirst(RegExp(r'/+$'), '');
    if (!path.endsWith('/chat/completions')) {
      throw const FormatException(
        'Add this provider’s Models URL under Advanced.',
      );
    }
    return chat.replace(
      path:
          path.substring(0, path.length - '/chat/completions'.length) +
          '/models',
    );
  }

  Map<String, String> get authenticationHeaders {
    validateCredential();
    return switch (protocol) {
      AiProviderProtocol.gemini => {'x-goog-api-key': key},
      AiProviderProtocol.anthropicMessages => {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
      },
      AiProviderProtocol.chatCompletions => {'Authorization': 'Bearer $key'},
    };
  }

  Uri get uri {
    responseTimeout;
    validateCredential();
    if (!validModelId(model)) {
      throw const FormatException('Choose an available model first.');
    }
    switch (protocol) {
      case AiProviderProtocol.gemini:
        if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(model)) {
          throw const FormatException('Choose a valid Gemini model.');
        }
        return Uri.parse('${definition.baseUrl}/models/$model:generateContent');
      case AiProviderProtocol.anthropicMessages:
        return Uri.parse('${definition.baseUrl}/messages');
      case AiProviderProtocol.chatCompletions:
        return definition.isCustom
            ? _customChatUri
            : Uri.parse('${definition.baseUrl}/chat/completions');
    }
  }
}
