import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../domain/ai_protocol.dart';
import '../domain/local_ai_protocol.dart';
import 'aaris_default_ai_service.dart';
import 'local_ai_service.dart';

class AiConfiguration {
  const AiConfiguration({
    this.provider = 'Gemini',
    this.model = '',
    this.endpoint = '',
    this.key = '',
    this.localBrainEnabled = false,
  });
  final String provider, model, endpoint, key;
  final bool localBrainEnabled;

  AiConfiguration copyWith({
    String? provider,
    String? model,
    String? endpoint,
    String? key,
    bool? localBrainEnabled,
  }) => AiConfiguration(
    provider: provider ?? this.provider,
    model: model ?? this.model,
    endpoint: endpoint ?? this.endpoint,
    key: key ?? this.key,
    localBrainEnabled: localBrainEnabled ?? this.localBrainEnabled,
  );

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'model': model,
    'endpoint': endpoint,
    'key': key,
    'localBrainEnabled': localBrainEnabled,
  };
  factory AiConfiguration.fromJson(Map<String, dynamic> data) =>
      AiConfiguration(
        provider: data['provider'] as String? ?? 'Gemini',
        model: data['model'] as String? ?? '',
        endpoint: data['endpoint'] as String? ?? '',
        key: data['key'] as String? ?? '',
        localBrainEnabled: data['localBrainEnabled'] == true,
      );
  Uri get uri {
    if (model.trim().isEmpty || key.trim().isEmpty)
      throw const FormatException('Enter your model name and API key.');
    if (provider == 'Gemini') {
      if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(model))
        throw const FormatException('Enter a model name, not a URL.');
      return Uri.https(
        'generativelanguage.googleapis.com',
        '/v1beta/models/$model:generateContent',
      );
    }
    final value = Uri.tryParse(endpoint.trim());
    if (value == null ||
        value.scheme != 'https' ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment)
      throw const FormatException(
        'Enter a full HTTPS chat/completions endpoint without credentials or query parameters.',
      );
    return value;
  }
}

class AiService {
  static const _storage = FlutterSecureStorage();
  http.Client? _client;
  bool _localRequest = false;
  Future<AiConfiguration> loadConfiguration() async {
    final local = LocalAiService.instance;
    await local.initialize();
    final raw = await _storage.read(key: 'pharmacy.ai.configuration');
    final config = raw == null
        ? const AiConfiguration()
        : AiConfiguration.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (config.localBrainEnabled) await preparePreferredLocalRoute();
    return config;
  }

  Future<void> saveConfiguration(AiConfiguration config) async {
    await _storage.write(
      key: 'pharmacy.ai.configuration',
      value: jsonEncode(config.toJson()),
    );
  }

  Future<void> forgetKey() => _storage.delete(key: 'pharmacy.ai.configuration');
  void cancel() {
    if (_localRequest) LocalAiService.instance.cancelRequest();
    _client?.close();
    _client = null;
  }

  /// Resolves the privacy-first inference route without sending any inventory.
  ///
  /// A user-selected local model remains authoritative. If none is selected,
  /// an installed Aaris Default AI is restored before the UI decides whether a
  /// cloud connection is required. This closes the cold-start gap where an
  /// installed default existed on disk but had not yet been activated in this
  /// process.
  Future<bool> preparePreferredLocalRoute() async {
    final local = LocalAiService.instance;
    await local.initialize();
    await AarisDefaultAiService.instance.ensureActiveIfInstalled();
    return local.hasSelection;
  }

  Future<String> ask(
    AiConfiguration config,
    PharmacyExport Function() exportData,
    String instruction, {
    required LocalInventoryContext localContext,
    String conversation = '',
  }) async {
    final local = LocalAiService.instance;

    // One explicit route owns typed chat. Local failures never fall through to
    // the API; API mode never wakes or consults the local model.
    if (config.localBrainEnabled) {
      final hasLocalRoute = await preparePreferredLocalRoute();
      if (!hasLocalRoute) {
        throw StateError(
          'Aaris Brain is on, but no local model is selected. Choose a model or turn Aaris Brain off.',
        );
      }
      _localRequest = true;
      try {
        return await local.ask(
          localContext,
          instruction,
          conversation: conversation,
        );
      } finally {
        _localRequest = false;
      }
    }
    if (_client != null) throw StateError('An AI request is already running.');
    final endpoint = config.uri;
    final data = exportData();
    if (instruction.trim().isEmpty)
      throw const FormatException('Describe what you want the AI to do.');
    if (data.content.length > 700000)
      throw const FormatException(
        'This inventory is too large for an in-app request. Use the TXT export with your AI instead.',
      );
    final client = http.Client();
    _client = client;
    try {
      final payload = '${data.content}\n\nOWNER REQUEST:\n$instruction';
      final body = config.provider == 'Gemini'
          ? {
              'system_instruction': {
                'parts': [
                  {'text': data.prompt},
                ],
              },
              'contents': [
                {
                  'role': 'user',
                  'parts': [
                    {'text': payload},
                  ],
                },
              ],
              'generationConfig': {'responseMimeType': 'application/json'},
            }
          : {
              'model': config.model,
              'messages': [
                {'role': 'system', 'content': data.prompt},
                {'role': 'user', 'content': payload},
              ],
            };
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': 'application/json',
          if (config.provider == 'Gemini')
            'x-goog-api-key': config.key
          else
            'Authorization': 'Bearer ${config.key}',
        })
        ..body = jsonEncode(body);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw StateError(
          'AI provider returned HTTP ${response.statusCode}. Check the model, key, quota and endpoint.',
        );
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 1500000)
          throw StateError('AI response is too large. Ask for fewer changes.');
      }
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (config.provider == 'Gemini') {
        final candidates = decoded['candidates'] as List?;
        if (candidates == null || candidates.isEmpty)
          throw StateError(
            'The AI did not return a response. Try a smaller, clearer request.',
          );
        return ((candidates.first as Map)['content']['parts'] as List)
            .map((p) => (p as Map)['text'] ?? '')
            .join('\n');
      }
      final choices = decoded['choices'] as List?;
      if (choices == null || choices.isEmpty)
        throw StateError(
          'The endpoint did not return a compatible chat response.',
        );
      final content = (choices.first as Map)['message']['content'];
      if (content is! String)
        throw StateError('The provider did not return a text response.');
      return content;
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }
}

Future<void> sharePharmacy(PharmacyExport data) async {
  await Clipboard.setData(ClipboardData(text: data.prompt));
  await SharePlus.instance.share(
    ShareParams(
      title: 'Aaris Pharmacy inventory',
      text: data.prompt,
      files: [
        XFile.fromData(
          utf8.encode('${data.prompt}\n\n${data.content}'),
          mimeType: 'text/plain',
        ),
      ],
      fileNameOverrides: [data.fileName],
    ),
  );
}
