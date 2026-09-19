import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../domain/local_ai_protocol.dart';
import '../domain/local_scan_handoff.dart';
import '../domain/medicine_understanding.dart';
import '../domain/ai_configuration.dart';
import 'ai_provider_adapter.dart';
import 'bounded_ai_response.dart';

/// Privacy-bounded cloud medicine-pack refinement.
///
/// This service never receives an inventory export and never writes inventory.
/// It sends only the bounded OCR handoff for one deterministic medicine draft,
/// then runs the same quote/evidence validator used by Local AI before returning
/// a preview candidate. A direct camera flow may pass that validated candidate
/// through the authoritative machine-commit gate; all other callers keep the
/// existing review/Confirm boundary. One instance belongs to one review session,
/// so cancellation cannot cross navigation sessions.
class CloudScanAiService {
  CloudScanAiService({
    http.Client Function()? clientFactory,
    Duration responseTimeout = const Duration(seconds: 35),
  }) : assert(responseTimeout > Duration.zero),
       _responseTimeout = responseTimeout,
       _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  final Duration _responseTimeout;

  static const _storage = FlutterSecureStorage();
  static const _configurationKey = 'pharmacy.ai.configuration';
  static const _maxResponseBytes = 1500000;
  static const _sourceLimit = 7000;
  static const _transientStatuses = <int>{
    408,
    425,
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
  bool _requestActive = false;
  int _requestEpoch = 0;

  bool get busy => _requestActive;

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
    final raw = await _storage.read(key: _configurationKey)
        .timeout(const Duration(seconds: 4));
    if (raw == null || raw.trim().isEmpty) {
      throw StateError(
        'Connect a cloud API first in AI Controller → Settings → Use AI inside the app.',
      );
    }
    final config = AiConfiguration.fromStored(raw);
    // This validates model/key and the HTTPS endpoint before any OCR can leave
    // the device. It also rejects credentials/query fragments embedded in URLs.
    config.uri;
    return config;
  }

  String routeLabel(AiConfiguration config) =>
      '${config.providerLabel} · ${config.model.trim()}';

  Future<MedicineScanDraft> refine(
    AiConfiguration config,
    MedicineScanDraft draft,
  ) async {
    if (busy) {
      throw StateError(
        'Cloud scan AI is already reviewing another draft. Finish or cancel it first.',
      );
    }
    final epoch = _requestEpoch;
    _requestActive = true;
    try {
      final handoff = LocalScanHandoff.fromDraft(
        draft,
        sourceLimit: _sourceLimit,
      );
      config.uri;
      final adapter = AiProviderAdapter.forConfiguration(config);
      Object? lastTransient;

      for (var attempt = 0; attempt < 2; attempt++) {
        _checkEpoch(epoch);
        final client = _clientFactory();
        _client = client;
        try {
          final response = await client
              .send(adapter.request(
                config: config,
                system: handoff.systemPrompt,
                user: handoff.userPayload,
                stream: false,
                maxOutputTokens: 1000,
              ))
              .timeout(const Duration(seconds: 50));
          _checkEpoch(epoch);
          final bytes = await _readBounded(response, epoch);
          _checkEpoch(epoch);
          if (response.statusCode < 200 || response.statusCode >= 300) {
            final failure = AiProviderFailure.http(response.statusCode);
            if (attempt == 0 &&
                _transientStatuses.contains(response.statusCode)) {
              lastTransient = failure;
            } else {
              throw failure;
            }
          } else {
            final modelText = adapter.decode(bytes);
            final object = localJsonObject(modelText);
            return validateLocalScan(draft, object, sourceLimit: _sourceLimit);
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
    } finally {
      _requestActive = false;
    }
  }

  Future<List<int>> _readBounded(
    http.StreamedResponse response,
    int epoch,
  ) => collectAiResponse(
    response.stream,
    deadline: _responseTimeout,
    checkCurrent: () => _checkEpoch(epoch),
    maxBytes: _maxResponseBytes,
  );
}
