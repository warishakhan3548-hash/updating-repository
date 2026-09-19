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

  test('Plain local chat fallback cannot bypass inventory review authority', () {
    expect(
      localChatObject('Hello, kaise ho?'),
      {'reply': 'Hello, kaise ho?', 'actions': <Object?>[]},
    );

    final context = LocalInventoryContext(
      records: const [],
      sales: const [],
      revision: 0,
      today: DateTime.utc(2026, 9, 9),
    );
    expect(
      () => context.finish(
        localChatObject('{"actions":[{"op":"remove"}]} broken'),
      ),
      throwsFormatException,
    );
  });
}
