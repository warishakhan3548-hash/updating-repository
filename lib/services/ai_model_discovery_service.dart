import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/ai_configuration.dart';
import '../domain/ai_discovered_model.dart';
import 'ai_provider_adapter.dart';

class AiConnectionFailure implements Exception {
  const AiConnectionFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Separate transport ownership from chat and scans. Closing the editor only
/// cancels discovery/test requests. No inventory is passed to this service.
class AiModelDiscoveryService {
  AiModelDiscoveryService({
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 40),
    this.maxBytes = 4 * 1024 * 1024,
  }) : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  final Duration timeout;
  final int maxBytes;
  http.Client? _client;
  int _epoch = 0;

  void cancel() {
    ++_epoch;
    _client?.close();
    _client = null;
  }

  Future<T> _run<T>(
    Future<T> Function(http.Client, Stopwatch, int) action,
  ) async {
    cancel();
    final epoch = _epoch;
    final client = _clientFactory();
    _client = client;
    final watch = Stopwatch()..start();
    try {
      return await action(client, watch, epoch).timeout(timeout);
    } on TimeoutException {
      throw const AiConnectionFailure(
        'Connection timed out. Check your network and retry.',
      );
    } on AiConnectionFailure {
      rethrow;
    } on FormatException {
      throw const AiConnectionFailure(
        'The provider returned an incompatible response.',
      );
    } catch (_) {
      // Transport exceptions and provider bodies may echo the API key/URL.
      throw const AiConnectionFailure(
        'Could not connect. Check the network and provider settings.',
      );
    } finally {
      watch.stop();
      client.close();
      if (identical(_client, client)) {
        ++_epoch; // Retire any continuation left behind by a timeout.
        _client = null;
      }
    }
  }

  void _check(int epoch) {
    if (epoch != _epoch)
      throw const AiConnectionFailure('Connection request cancelled.');
  }

  Duration _remaining(Stopwatch watch) {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero)
      throw TimeoutException('Connection deadline');
    return remaining;
  }

  Future<List<int>> _send(
    http.Client client,
    http.Request request,
    Stopwatch watch,
    int epoch,
    int byteLimit, {
    bool discovery = false,
  }) async {
    _check(epoch);
    request.followRedirects = false;
    final response = await client.send(request).timeout(_remaining(watch));
    _check(epoch);
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw AiConnectionFailure(switch (status) {
        401 || 403 =>
          'This key cannot access ${discovery ? 'the model list' : 'this model'}. Check the key and account permissions.',
        429 => 'Provider quota or rate limit reached. Check your balance or retry later.',
        404 || 405 when discovery => 'This provider does not expose this model list. Check Advanced settings or use manual setup.',
        404 => 'This model is unavailable for your key. Refresh models and select another.',
        400 || 405 || 415 || 422 => 'This model or endpoint does not support the app’s text request. Choose another model.',
        >= 300 && < 400 =>
          'The provider redirected the request. Check its official endpoint.',
        _ => 'Provider temporarily unavailable (HTTP $status). Retry later.',
      });
    }
    if ((response.contentLength ?? 0) > byteLimit) {
      throw const AiConnectionFailure('Provider response is too large.');
    }
    final bytes = BytesBuilder(copy: false);
    final chunks = StreamIterator<List<int>>(response.stream);
    try {
      while (await chunks.moveNext().timeout(_remaining(watch))) {
        _check(epoch);
        if (bytes.length + chunks.current.length > byteLimit) {
          throw const AiConnectionFailure('Provider response is too large.');
        }
        bytes.add(chunks.current);
      }
    } finally {
      await chunks.cancel();
    }
    _check(epoch);
    return bytes.takeBytes();
  }

  Future<List<AiDiscoveredModel>> discover(AiConfiguration config) {
    final base = config.modelsUri; // Validate before creating a transport.
    final headers = config.authenticationHeaders;
    return _run((client, watch, epoch) async {
      var uri = base;
      var bytesLeft = maxBytes;
      final found = <String, AiDiscoveredModel>{};
      final cursors = <String>{};
      for (var page = 0; page < 20; page++) {
        final request = http.Request('GET', uri)
          ..headers.addAll({'Accept': 'application/json', ...headers});
        final bytes = await _send(
          client,
          request,
          watch,
          epoch,
          bytesLeft,
          discovery: true,
        );
        bytesLeft -= bytes.length;
        final data = jsonDecode(utf8.decode(bytes));
        for (final model in AiDiscoveredModel.parse(data, config)) {
          found[model.id] = model;
        }
        if (found.length > 3000)
          throw const AiConnectionFailure(
            'Provider returned too many models. Narrow the provider catalog.',
          );
        String? cursor;
        String? parameter;
        if (data is Map) {
          if (config.protocol == AiProviderProtocol.gemini) {
            final next = data['nextPageToken'];
            if (next != null && next is! String) throw const FormatException();
            if (next is String && next.isNotEmpty) {
              cursor = next;
              parameter = 'pageToken';
            }
          } else if (data['has_more'] == true) {
            final next = data['last_id'];
            if (next is! String || next.isEmpty) throw const FormatException();
            cursor = next;
            parameter = config.protocol == AiProviderProtocol.anthropicMessages
                ? 'after_id'
                : 'after';
          }
        }
        if (cursor == null) {
          return found.values.toList()..sort(
            (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
          );
        }
        if (cursor.length > 2048 || !cursors.add(cursor))
          throw const AiConnectionFailure(
            'Provider returned invalid model pagination.',
          );
        // Only a token is accepted, never a provider-supplied continuation URL.
        uri = base.replace(queryParameters: {parameter!: cursor});
      }
      throw const AiConnectionFailure(
        'Provider model list is incomplete. Retry or narrow the provider catalog.',
      );
    });
  }

  /// A small explicit inference probe confirms access, not merely a public
  /// model listing. Uses the same wire adapter as real chat and OCR refinement.
  Future<void> testModel(AiConfiguration config) {
    config.uri;
    return _run((client, watch, epoch) async {
      final adapter = AiProviderAdapter.forConfiguration(config);
      final request = adapter.request(
        config: config,
        system: 'Return a short JSON object only.',
        user: 'Connection test. Reply with {"ok":true}.',
        stream: false,
        maxOutputTokens: 1024,
      );
      final bytes = await _send(client, request, watch, epoch, 64 * 1024);
      final text = adapter.decode(bytes);
      if (text.trim().isEmpty)
        throw const AiConnectionFailure(
          'This model returned no usable text. Choose another model.',
        );
    });
  }
}
