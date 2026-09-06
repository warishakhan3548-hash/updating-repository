import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ludo_masti/game/dice_roll_models.dart';
import 'package:voice_ludo_masti/game/ludo_engine.dart';
import 'package:voice_ludo_masti/services/voice_dice_controller.dart';

void main() {
  PendingVoiceDiceIntent intentFor(
    TurnBinding binding,
    int value,
    DateTime recognizedAt,
  ) =>
      PendingVoiceDiceIntent(
        matchId: binding.matchId,
        playerId: binding.playerId,
        turnId: binding.turnId,
        requestedValue: value,
        recognizedAt: recognizedAt,
        expiresAt: recognizedAt.add(const Duration(minutes: 1)),
      );

  group('High-confidence dice parser', () {
    test('required Hindi and English values map correctly', () {
      expect(VoiceDiceController.parseLastDiceValue('छक्का'), 6);
      expect(VoiceDiceController.parseLastDiceValue('six'), 6);
      expect(VoiceDiceController.parseLastDiceValue('छह'), 6);
      expect(VoiceDiceController.parseLastDiceValue('four'), 4);
      expect(VoiceDiceController.parseLastDiceValue('पाँच'), 5);
      expect(VoiceDiceController.parseLastDiceValue('एक'), 1);
      expect(VoiceDiceController.parseLastDiceValue('दो'), 2);
      expect(VoiceDiceController.parseLastDiceValue('तीन'), 3);
    });

    test('fast and quiet ASR variants map to the intended dice value', () {
      expect(VoiceDiceController.parseLastDiceValue('छक्क'), 6);
      expect(VoiceDiceController.parseLastDiceValue('छक'), 6);
      expect(VoiceDiceController.parseLastDiceValue('चका'), 6);
      expect(VoiceDiceController.parseLastDiceValue('शक्का'), 6);
      expect(VoiceDiceController.parseLastDiceValue('chaka'), 6);
      expect(VoiceDiceController.parseLastDiceValue('chhaka'), 6);
      expect(VoiceDiceController.parseLastDiceValue('छ'), 6);
      expect(VoiceDiceController.parseLastDiceValue('chhe'), 6);
      expect(VoiceDiceController.parseLastDiceValue('फौर'), 4);
      expect(VoiceDiceController.parseLastDiceValue('panj'), 5);
      expect(VoiceDiceController.parseLastDiceValue('पान्च'), 5);
      expect(VoiceDiceController.parseLastDiceValue('छको'), 6);
      expect(VoiceDiceController.parseLastDiceValue('chhakkaa'), 6);
    });

    test('natural command phrases work without blind substring matching', () {
      expect(VoiceDiceController.parseLastDiceValue('छक्का दे'), 6);
      expect(VoiceDiceController.parseLastDiceValue('छक्का चाहिए'), 6);
      expect(VoiceDiceController.parseLastDiceValue('give me six'), 6);
      expect(VoiceDiceController.parseLastDiceValue('चार आना चाहिए'), 4);
      expect(VoiceDiceController.parseLastDiceValue('छक्का दे दो'), 6);
      expect(VoiceDiceController.parseLastDiceValue('हाँ छक्का'), 6);
      expect(VoiceDiceController.parseLastDiceValue('अरे पाँच'), 5);
      expect(VoiceDiceController.parseLastDiceValue('कर दो'), isNull);
      expect(VoiceDiceController.parseLastDiceValue('करो दो'), isNull);
      expect(VoiceDiceController.parseLastDiceValue('we have six players'), isNull);
      expect(VoiceDiceController.parseLastDiceValue('six o clock'), isNull);
    });

    test('dice-only partial phrases are distinguishable from sentence prefixes', () {
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('छक्का'), isTrue);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('छक्का छक्का'), isTrue);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('six six'), isTrue);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('पाँच पाँच'), isTrue);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('six players'), isFalse);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('मुझे छक्का दे'), isFalse);
    });


    test('partial fast path is precise while common quiet variants stay instant', () {
      expect(DiceVoiceIntentParser.isFastPartialCommand('छक्का'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('छका'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('छक्का छक्का'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('six six'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('पान्च'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('chhakkaa'), isTrue);

      expect(DiceVoiceIntentParser.isFastPartialCommand('छ'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('सिक'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('tin'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('char'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('six five'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('give me six'), isFalse);
    });
  });

  group('Turn-bound voice intents', () {
    test('command belongs only to the exact active match/player/turn', () {
      final engine = LudoEngine(playerCount: 2);
      final now = DateTime(2026, 9, 5, 12);
      final binding = engine.voiceTurnBinding;

      expect(engine.acceptVoiceDiceIntent(intentFor(binding, 6, now), now: now), isTrue);
      final result = engine.reserveDiceRoll(randomDice: () => 2, now: now);

      expect(result?.value, 6);
      expect(result?.source, DiceRollSource.voice);
      expect(result?.binding, binding);
    });

    test('old-turn delayed command cannot affect the new player', () {
      final engine = LudoEngine(playerCount: 2);
      final now = DateTime(2026, 9, 5, 12);
      final oldBinding = engine.voiceTurnBinding;
      final delayed = intentFor(oldBinding, 6, now);

      engine.beginRolling();
      engine.commitRoll(5);

      expect(engine.voiceTurnBinding, isNot(oldBinding));
      expect(engine.currentColor, LudoColor.yellow);
      expect(
        engine.acceptVoiceDiceIntent(delayed, now: now.add(const Duration(seconds: 1))),
        isFalse,
      );
      expect(
        engine.reserveDiceRoll(randomDice: () => 3, now: now.add(const Duration(seconds: 1)))?.value,
        3,
      );
    });

    test('voice command is consumed exactly once', () {
      final engine = LudoEngine(playerCount: 2);
      final now = DateTime(2026, 9, 5, 12);
      final binding = engine.voiceTurnBinding;
      engine.acceptVoiceDiceIntent(intentFor(binding, 6, now), now: now);

      final first = engine.reserveDiceRoll(randomDice: () => 1, now: now);
      expect(first?.value, 6);
      expect(engine.pendingVoiceDiceIntent, isNull);
      expect(engine.lastConsumedVoiceIntent?.consumed, isTrue);

      engine.beginRolling();
      engine.commitRoll(6);
      engine.moveToken(0);

      final second = engine.reserveDiceRoll(
        randomDice: () => 2,
        now: now.add(const Duration(seconds: 1)),
      );
      expect(second?.source, DiceRollSource.random);
      expect(second?.value, 2);
    });

    test('first accepted same-turn command owns the roll generation', () {
      final engine = LudoEngine(playerCount: 2);
      final base = DateTime(2026, 9, 5, 12);
      final binding = engine.voiceTurnBinding;

      expect(engine.acceptVoiceDiceIntent(intentFor(binding, 4, base), now: base), isTrue);
      expect(
        engine.acceptVoiceDiceIntent(
          intentFor(binding, 6, base.add(const Duration(milliseconds: 200))),
          now: base.add(const Duration(milliseconds: 200)),
        ),
        isFalse,
      );
      expect(
        engine.acceptVoiceDiceIntent(
          intentFor(binding, 2, base.add(const Duration(milliseconds: 100))),
          now: base.add(const Duration(milliseconds: 300)),
        ),
        isFalse,
      );

      expect(
        engine.reserveDiceRoll(
          randomDice: () => 1,
          now: base.add(const Duration(milliseconds: 400)),
        )?.value,
        4,
      );
    });

    test('no command falls back to normal random dice', () {
      final engine = LudoEngine(playerCount: 2);
      final result = engine.reserveDiceRoll(randomDice: () => 4);
      expect(result?.source, DiceRollSource.random);
      expect(result?.value, 4);
    });

    test('simultaneous tap/voice race freezes the first resolved roll', () {
      final engine = LudoEngine(playerCount: 2);
      final base = DateTime(2026, 9, 5, 12);
      final binding = engine.voiceTurnBinding;
      engine.acceptVoiceDiceIntent(intentFor(binding, 4, base), now: base);

      final reserved = engine.reserveDiceRoll(
        randomDice: () => 1,
        now: base.add(const Duration(milliseconds: 10)),
      );
      expect(reserved?.value, 4);

      expect(
        engine.acceptVoiceDiceIntent(
          intentFor(binding, 6, base.add(const Duration(milliseconds: 20))),
          now: base.add(const Duration(milliseconds: 20)),
        ),
        isFalse,
      );
      expect(engine.reserveDiceRoll(randomDice: () => 2), isNull);

      engine.beginRolling();
      expect(engine.activeRollResult?.value, 4);
      expect(() => engine.commitRoll(6), throwsStateError);
      engine.commitRoll(4);
    });

    test('extra turn receives a fresh hidden turn sequence', () {
      final engine = LudoEngine(playerCount: 2);
      final oldBinding = engine.voiceTurnBinding;

      final reserved = engine.reserveDiceRoll(randomDice: () => 6)!;
      engine.beginRolling();
      engine.commitRoll(reserved.value);
      engine.moveToken(0);

      expect(engine.currentColor, LudoColor.red);
      expect(engine.voiceTurnBinding.playerId, oldBinding.playerId);
      expect(engine.voiceTurnBinding.turnId, greaterThan(oldBinding.turnId));
      expect(
        engine.acceptVoiceDiceIntent(
          intentFor(oldBinding, 5, DateTime.now()),
          now: DateTime.now(),
        ),
        isFalse,
      );
    });

    test('match restart invalidates every command from the old match', () {
      final engine = LudoEngine(playerCount: 2);
      final oldBinding = engine.voiceTurnBinding;
      final oldIntent = intentFor(oldBinding, 6, DateTime.now());

      engine.reset(2);

      expect(engine.voiceTurnBinding.matchId, isNot(oldBinding.matchId));
      expect(engine.acceptVoiceDiceIntent(oldIntent), isFalse);
    });

    test('expired same-turn command is ignored safely', () {
      final engine = LudoEngine(playerCount: 2);
      final binding = engine.voiceTurnBinding;
      final recognizedAt = DateTime(2026, 9, 5, 12);
      final expired = PendingVoiceDiceIntent(
        matchId: binding.matchId,
        playerId: binding.playerId,
        turnId: binding.turnId,
        requestedValue: 6,
        recognizedAt: recognizedAt,
        expiresAt: recognizedAt.add(const Duration(seconds: 1)),
      );

      expect(
        engine.acceptVoiceDiceIntent(
          expired,
          now: recognizedAt.add(const Duration(seconds: 2)),
        ),
        isFalse,
      );
      expect(
        engine.reserveDiceRoll(
          randomDice: () => 5,
          now: recognizedAt.add(const Duration(seconds: 2)),
        )?.value,
        5,
      );
    });

    test('logical frozen result and committed game result cannot diverge', () {
      final engine = LudoEngine(playerCount: 2);
      final result = engine.resolveDiceRoll(randomDice: () => 6)!;

      expect(engine.isRolling, isTrue);
      expect(engine.activeRollResult, result);
      expect(() => engine.commitRoll(3), throwsStateError);
      expect(engine.commitResolvedRoll(result), isTrue);
      expect(engine.currentRoll, 6);
    });

    test('manual gameplay works with no voice intent at all', () {
      final engine = LudoEngine(playerCount: 2);
      final result = engine.resolveDiceRoll(randomDice: () => 5)!;
      expect(result.source, DiceRollSource.random);
      expect(engine.commitResolvedRoll(result), isTrue);
      expect(engine.currentColor, LudoColor.yellow);
      expect(engine.canRoll, isTrue);
    });

    test('ending the match voice session clears the pending command', () async {
      final engine = LudoEngine(playerCount: 2);
      final controller = VoiceDiceController(engine: engine);
      final now = DateTime(2026, 9, 5, 12);
      final binding = engine.voiceTurnBinding;

      expect(engine.acceptVoiceDiceIntent(intentFor(binding, 6, now), now: now), isTrue);
      expect(engine.pendingVoiceDiceIntent?.requestedValue, 6);

      await controller.endMatchSession();

      expect(engine.pendingVoiceDiceIntent, isNull);
      expect(controller.listening, isFalse);
      expect(controller.binding, isNull);

      controller.dispose();
      engine.dispose();
    });
  });
}
