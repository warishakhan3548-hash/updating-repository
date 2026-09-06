import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ludo_masti/services/voice_dice_controller.dart';

void main() {
  group('N-best dice hypothesis arbitration', () {
    test('same-value partial alternatives commit immediately', () {
      final parsed = DiceVoiceIntentParser.selectBestHypothesis(
        const ['छक्का', 'छका', 'six'],
        recognitionConfidences: const [null, null, null],
        isFinal: false,
      );
      expect(parsed?.value, 6);
    });

    test('conflicting unmeasured partial waits for final result', () {
      final parsed = DiceVoiceIntentParser.selectBestHypothesis(
        const ['six', 'five'],
        recognitionConfidences: const [null, null],
        isFinal: false,
      );
      expect(parsed, isNull);
    });

    test('clear acoustic confidence can overtake provider rank', () {
      final parsed = DiceVoiceIntentParser.selectBestHypothesis(
        const ['five', 'six'],
        recognitionConfidences: const [.31, .96],
        isFinal: true,
      );
      expect(parsed?.value, 6);
    });

    test('near-tied measured final values fail closed', () {
      final parsed = DiceVoiceIntentParser.selectBestHypothesis(
        const ['six', 'five'],
        recognitionConfidences: const [.81, .80],
        isFinal: true,
      );
      expect(parsed, isNull);
    });
  });

  test('Ludo engine no longer exposes a mutable global voice engine bridge', () {
    final source = File('lib/game/ludo_engine.dart').readAsStringSync();
    expect(source, isNot(contains('_voiceRuntimeEngine')));
    expect(source, isNot(contains('voiceRuntimeEngine')));
  });
}
