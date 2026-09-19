import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import '../lib/domain/ai_configuration.dart';
import '../lib/domain/medicine_understanding.dart';
import '../lib/services/ai_provider_adapter.dart';
import '../lib/services/cloud_scan_ai_service.dart';

void main() {
  AiConfiguration config(String provider, {
    String endpoint = 'https://provider.example/v1',
    bool? jsonMode,
  }) => AiConfiguration(
    provider: provider, model: 'example-model', key: 'fixture-credential',
    endpoint: endpoint, jsonModeEnabled: jsonMode,
  );

  test('legacy compatible configuration and proxy base URLs remain valid', () {
    final old = AiConfiguration.fromJson({
      'provider': 'Compatible', 'model': 'example-model',
      'key': 'fixture-credential',
      'endpoint': 'https://provider.example/proxy/v1/chat/completions',
      'localBrainEnabled': true,
    });
    expect(old.uri.path, '/proxy/v1/chat/completions');
    expect(old.streamingEnabled, isTrue);
    expect(old.useJsonMode, isFalse);
    expect(old.copyWith(streamingEnabled: false).localBrainEnabled, isTrue);
    expect(config('Compatible').uri.path, '/v1/chat/completions');
    expect(config('OpenAI-compatible',
      endpoint: 'https://provider.example/proxy/v1/').uri.path,
      '/proxy/v1/chat/completions');
  });

  test('unknown protocols and credential-bearing URLs fail before transport', () {
    expect(() => config('Unknown').uri, throwsFormatException);
    for (final endpoint in [
      'http://provider.example/v1', 'https://key@provider.example/v1',
      'https://provider.example/v1?key=x', 'https://provider.example/v1#key',
    ]) {
      expect(() => config('Compatible', endpoint: endpoint).uri,
        throwsFormatException);
    }
    expect(() => AiConfiguration.fromJson({'streamingEnabled': 'yes'}),
      throwsFormatException);
  });

  test('minimal compatible request does not assume optional JSON capability', () {
    final saved = config('Compatible');
    final adapter = AiProviderAdapter.forConfiguration(saved);
    final request = adapter.request(
      config: saved, system: 'Return JSON.', user: 'Observed OCR only.',
      stream: false, maxOutputTokens: 1000,
    );
    final body = jsonDecode(request.body) as Map;
    expect(body.containsKey('stream'), isFalse);
    expect(body.containsKey('response_format'), isFalse);
    expect(body.containsKey('max_tokens'), isFalse);
    expect(request.followRedirects, isFalse);
    final capable = saved.copyWith(jsonModeEnabled: true);
    expect(jsonDecode(adapter.request(config: capable, system: 'Return JSON.',
      user: 'OCR', stream: true).body)['response_format'],
      {'type': 'json_object'});
  });

  test('provider authentication stays on the selected protocol endpoint', () {
    final saved = config('Anthropic');
    final request = AiProviderAdapter.forConfiguration(saved).request(
      config: saved, system: 'Return JSON.', user: 'OCR', stream: true,
      maxOutputTokens: 1000,
    );
    expect(request.url.host, 'api.anthropic.com');
    expect(request.url.path, '/v1/messages');
    expect(request.headers['x-api-key'], 'fixture-credential');
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(request.headers['anthropic-version'], '2023-06-01');
    expect(jsonDecode(request.body)['max_tokens'], 1000);
    expect(() => AiProviderAdapter.forConfiguration(
      saved.copyWith(jsonModeEnabled: true)), throwsStateError);
  });

  test('Gemini thought parts never enter final medicine JSON', () {
    final adapter = AiProviderAdapter.forConfiguration(config('Gemini'));
    expect(adapter.text({
      'candidates': [{'content': {'parts': [
        {'text': 'private reasoning', 'thought': true},
        {'text': '{"fields":{}}'},
      ]}}],
    }), '{"fields":{}}');
  });

  test('Anthropic ignores thinking and waits for message completion', () {
    final adapter = AiProviderAdapter.forConfiguration(config('Anthropic'));
    expect(adapter.delta({
      'type': 'content_block_delta',
      'delta': {'type': 'thinking_delta', 'thinking': 'not assistant output'},
    }), isEmpty);
    expect(adapter.delta({
      'type': 'content_block_delta',
      'delta': {'type': 'text_delta', 'text': '{"fields":{}}'},
    }), '{"fields":{}}');
    expect(adapter.terminal({'type': 'content_block_stop'}), isFalse);
    expect(adapter.terminal({'type': 'message_stop'}), isTrue);
  });

  test('compatible text gateways retain legacy deltas without reasoning output', () {
    final adapter = AiProviderAdapter.forConfiguration(config('Compatible'));
    expect(adapter.delta({'delta': 'text'}), 'text');
    expect(adapter.delta({'delta': {'text': 'text'}}), 'text');
    expect(adapter.delta({'type': 'response.output_text.delta', 'delta': 'text'}),
      'text');
    expect(adapter.delta({'type': 'reasoning_delta', 'delta': 'private'}), isEmpty);
    expect(adapter.delta({'delta': {'type': 'thinking_delta', 'text': 'private'}}),
      isEmpty);
    expect(adapter.delta({'choices': [{'delta': {'role': 'assistant'}}]}), isEmpty);
  });

  test('all cloud protocols use the same evidence validator', () async {
    const draft = MedicineScanDraft(fields: {}, rawText: 'ALPHA 500 mg',
      searchKeywords: '', frameSequences: [0]);
    for (final provider in ['Gemini', 'Compatible', 'Anthropic']) {
      final envelope = switch (provider) {
        'Gemini' => {'candidates': [{'content': {'parts': [
          {'text': '{"fields":{}}'},
        ]}}]},
        'Anthropic' => {'content': [
          {'type': 'text', 'text': '{"fields":{}}'},
        ]},
        _ => {'choices': [{'message': {'content': '{"fields":{}}'}}]},
      };
      final service = CloudScanAiService(
        clientFactory: () => MockClient((_) async =>
          http.Response(jsonEncode(envelope), 200)),
      );
      expect((await service.refine(config(provider), draft)).rawText, draft.rawText);
      expect(service.busy, isFalse);
    }
  });

  test('provider errors expose categories without echoing remote text', () {
    expect(AiProviderFailure.http(401).kind,
      AiProviderFailureKind.authentication);
    expect(AiProviderFailure.http(429).kind,
      AiProviderFailureKind.rateLimited);
    expect(AiProviderFailure.http(404).kind,
      AiProviderFailureKind.modelUnavailable);
    final adapter = AiProviderAdapter.forConfiguration(config('Compatible'));
    try {
      adapter.decode(utf8.encode('not JSON: fixture-credential'));
      fail('Expected malformed response');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains('fixture-credential')));
    }
  });
}
