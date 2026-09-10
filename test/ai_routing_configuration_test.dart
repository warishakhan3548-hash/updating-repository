import 'package:aaris_pharmacy/domain/local_ai_protocol.dart';
import 'package:aaris_pharmacy/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Aaris Brain route preference survives serialization', () {
    const config = AiConfiguration(
      provider: 'Gemini',
      model: 'gemini-test',
      key: 'secret',
      localBrainEnabled: true,
    );
    final restored = AiConfiguration.fromJson(config.toJson());
    expect(restored.localBrainEnabled, isTrue);
    expect(restored.key, 'secret');
    expect(restored.copyWith(localBrainEnabled: false).localBrainEnabled, isFalse);
  });

  test('Plain local chat fallback can never propose inventory changes', () {
    expect(
      localChatObject('Hello, kaise ho?'),
      {'reply': 'Hello, kaise ho?', 'actions': <Object?>[]},
    );
    expect(
      () => localChatObject('{"actions":[{"op":"remove"}]} broken'),
      throwsFormatException,
    );
  });
}
