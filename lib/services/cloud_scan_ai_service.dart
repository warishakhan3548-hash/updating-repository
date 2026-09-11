import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../domain/local_ai_protocol.dart';
import '../domain/local_scan_handoff.dart';
import '../domain/medicine_understanding.dart';
import 'ai_service.dart';

/// Explicit cloud-only medicine-pack refinement.
///
/// This service never receives an inventory export and never writes inventory.
/// It sends only the bounded OCR handoff for one deterministic medicine draft,
/// then runs the same quote/evidence validator used by Local AI before returning
/// a preview candidate. The caller still owns the existing Confirm/Add boundary.
class CloudScanAiService {
  CloudScanAiService._();

  static final instance = CloudScanAiService._();
  static const _storage = FlutterSecureStorage();
  static const _configurationKey = 'pharmacy.ai.configuration';
  static const _maxConfigurationCharacters = 64 * 1024;
  static const _maxResponseBytes = 1500000;
  static const _sourceLimit = 7000;
  static const _transientStatuses = <int>{
    408,
    425,
    429,
    500,
    502,
    503,
    504,
    520,
    521,
    522,
    523,
    524,
  };

  http.Client? _client;
  int _requestEpoch = 0;

  bool get busy => _client != null;

  /// Cancels only the currently owned cloud-scan transport. The provider never
  /// owns an inventory mutation, so abandoning a preview is always safe.
  void cancel() {
    ++_requestEpoch;
    _client?.close();
    _client = null;
  }

  void _checkEpoch(int epoch) {
    if (epoch != _requestEpoch) {
      throw StateError('Cloud scan AI request cancelled.');
    }
  }

  Future<AiConfiguration> requireConfiguration() async {
    final raw = await _storage.read(key: _configurationKey);
    if (raw == null || raw.trim().isEmpty) {
      throw StateError(
        'Connect a cloud API first in AI Controller → Settings → Use AI inside the app.',
      );
    }
    if (raw.length > _maxConfigurationCharacters) {
      throw const FormatException('Saved AI configuration is too large.');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Saved AI configuration is invalid.');
    }
    final config = AiConfiguration.fromJson(decoded);
    // This validates model/key and the HTTPS endpoint before any OCR can leave
    // the device. It also rejects credentials/query fragments embedded in URLs.
    config.uri;
    return config;
  }

  String routeLabel(AiConfiguration config) => config.provider == 'Gemini'
      ? 'Google Gemini · ${config.model.trim()}'
      : 'OpenAI-compatible · ${config.model.trim()}';

  Future<MedicineScanDraft> refine(
    AiConfiguration config,
    MedicineScanDraft draft,
  ) async {
    if (_client != null) {
      throw StateError(
        'Cloud scan AI is already reviewing another draft. Finish or cancel it first.',
      );
    }
    final epoch = _requestEpoch;
    final handoff = LocalScanHandoff.fromDraft(
      draft,
      sourceLimit: _sourceLimit,
    );
    final endpoint = config.uri;
    Object? lastTransient;

    for (var attempt = 0; attempt < 2; attempt++) {
      _checkEpoch(epoch);
      final client = http.Client();
      _client = client;
      try {
        final response = await client
            .send(_request(config, endpoint, handoff))
            .timeout(const Duration(seconds: 50));
        _checkEpoch(epoch);
        final bytes = await _readBounded(response, epoch);
        _checkEpoch(epoch);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final detail = _providerError(bytes);
          final message = detail.isEmpty
              ? 'Cloud scan provider returned HTTP ${response.statusCode}.'
              : 'Cloud scan provider returned HTTP ${response.statusCode}: $detail';
          if (attempt == 0 &&
              _transientStatuses.contains(response.statusCode)) {
            lastTransient = StateError(message);
          } else {
            throw StateError('$message No inventory changes were made.');
          }
        } else {
          final modelText = _decodeAssistantText(config, bytes);
          final object = localJsonObject(modelText);
          return validateLocalScan(
            draft,
            object,
            sourceLimit: _sourceLimit,
          );
        }
      } on TimeoutException catch (error) {
        _checkEpoch(epoch);
        lastTransient = error;
        if (attempt == 1) {
          throw TimeoutException(
            'Cloud scan AI timed out twice. Deterministic OCR is still available and no inventory changes were made.',
          );
        }
      } on http.ClientException catch (error) {
        _checkEpoch(epoch);
        lastTransient = error;
        if (attempt == 1) {
          throw StateError(
            'Cloud scan connection was interrupted twice. Deterministic OCR is still available and no inventory changes were made.',
          );
        }
      } finally {
        client.close();
        if (identical(_client, client)) _client = null;
      }

      _checkEpoch(epoch);
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        _checkEpoch(epoch);
      }
    }

    throw StateError(
      'Cloud scan AI could not finish: ${lastTransient ?? 'unknown transport error'}. No inventory changes were made.',
    );
  }

  http.Request _request(
    AiConfiguration config,
    Uri endpoint,
    LocalScanHandoff handoff,
  ) {
    final body = config.provider == 'Gemini'
        ? <String, Object?>{
            'system_instruction': {
              'parts': [
                {'text': handoff.systemPrompt},
              ],
            },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': handoff.userPayload},
                ],
              },
            ],
            'generationConfig': {
              'temperature': 0,
              'maxOutputTokens': 1000,
              'responseMimeType': 'application/json',
            },
          }
        : <String, Object?>{
            // Keep this request at the same lowest-common-denominator contract
            // as AiService's existing OpenAI-compatible chat route. Optional
            // generation knobs differ across compatible servers and must not make
            // a provider that already works for chat fail only for scanner OCR.
            'model': config.model,
            'messages': [
              {'role': 'system', 'content': handoff.systemPrompt},
              {'role': 'user', 'content': handoff.userPayload},
            ],
          };

    return http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (config.provider == 'Gemini')
          'x-goog-api-key': config.key
        else
          'Authorization': 'Bearer ${config.key}',
      })
      ..body = jsonEncode(body);
  }

  Future<List<int>> _readBounded(
    http.StreamedResponse response,
    int epoch,
  ) async {
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 35),
    )) {
      _checkEpoch(epoch);
      total += chunk.length;
      if (total > _maxResponseBytes) {
        throw StateError(
          'Cloud scan AI response is too large. No inventory changes were made.',
        );
      }
      bytes.add(chunk);
    }
    _checkEpoch(epoch);
    return bytes.takeBytes();
  }

  String _decodeAssistantText(
    AiConfiguration config,
    List<int> bytes,
  ) {
    final raw = utf8.decode(bytes, allowMalformed: true).trim();
    if (raw.isEmpty) {
      throw const FormatException('Cloud scan AI returned an empty response.');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Cloud scan AI returned incompatible JSON.');
    }

    if (config.provider == 'Gemini') {
      final candidates = decoded['candidates'];
      if (candidates is! List || candidates.isEmpty) {
        throw const FormatException('Gemini returned no scan candidate.');
      }
      final first = candidates.first;
      if (first is! Map) {
        throw const FormatException('Gemini returned an invalid scan candidate.');
      }
      final content = first['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is! List) {
        throw const FormatException('Gemini returned no scan content.');
      }
      final text = parts
          .whereType<Map>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();
      if (text.trim().isEmpty) {
        throw const FormatException('Gemini returned empty scan content.');
      }
      return text;
    }

    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException(
        'OpenAI-compatible provider returned no scan candidate.',
      );
    }
    final choice = choices.first as Map;
    final message = choice['message'];
    final content = message is Map ? message['content'] : null;
    if (content is String && content.trim().isNotEmpty) return content;
    if (content is List) {
      final text = content
          .whereType<Map>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();
      if (text.trim().isNotEmpty) return text;
    }
    final legacy = choice['text'];
    if (legacy is String && legacy.trim().isNotEmpty) return legacy;
    throw const FormatException(
      'OpenAI-compatible provider returned empty scan content.',
    );
  }

  String _providerError(List<int> bytes) {
    if (bytes.isEmpty) return '';
    final raw = utf8.decode(bytes, allowMalformed: true).trim();
    if (raw.isEmpty) return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final error = decoded['error'];
        final value = error is Map && error['message'] is String
            ? error['message'] as String
            : error is String
            ? error
            : decoded['message'] is String
            ? decoded['message'] as String
            : '';
        final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
        return clean.length <= 500 ? clean : '${clean.substring(0, 500)}…';
      }
    } on FormatException {
      // Do not surface HTML/proxy bodies or other infrastructure noise.
    }
    return '';
  }
}
