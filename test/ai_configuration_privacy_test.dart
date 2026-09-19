import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/ai_configuration.dart';
import '../lib/domain/local_ai_protocol.dart';

void main() {
  test('malformed structured AI output never exposes private source in errors', () {
    for (final raw in ['{"fields":"private-ocr",', 'reasoning {"fields": private-ocr}']) {
      try {
        localJsonObject(raw);
        fail('Malformed response was accepted');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('private-ocr')));
        expect(error.source, isNull);
      }
    }
    expect(localJsonObject('reasoning {"fields":{}}'), {'fields': {}});
  });

  test('invalid stored JSON cannot expose a credential through the exception', () {
    const credential = 'private-credential-sentinel';
    for (final raw in [
      '{"key":"$credential",',
      '{"provider":"Unknown","key":"$credential"}',
      '["$credential"]',
    ]) {
      try {
        AiConfiguration.fromStored(raw);
        fail('Invalid configuration was accepted');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains(credential)));
        expect(error.source, isNull);
      }
    }
  });

  test('secure decoding preserves legacy local routing and cloud credentials', () {
    final config = AiConfiguration.fromStored(jsonEncode({
      'provider': 'OpenAI-compatible',
      'endpoint': 'https://example.com/v1/chat/completions',
      'model': 'selected-model', 'key': 'saved-key', 'localBrainEnabled': true,
    }));
    expect(config.localBrainEnabled, isTrue);
    expect(config.key, 'saved-key');
    expect(config.streamingEnabled, isTrue);
    expect(config.copyWith(key: '').localBrainEnabled, isTrue);
  });

  test('missing configuration stays offline and oversized envelopes are bounded', () {
    expect(AiConfiguration.fromStored(null).key, isEmpty);
    expect(() => AiConfiguration.fromStored(' ' * (64 * 1024 + 1)),
      throwsFormatException);
  });
}
