import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ludo_masti/game/dice_roll_models.dart';
import 'package:voice_ludo_masti/game/ludo_engine.dart';

void main() {
  test('first accepted voice command owns the current roll generation', () {
    final engine = LudoEngine(playerCount: 2);
    addTearDown(engine.dispose);

    final binding = engine.voiceTurnBinding;
    final baseTime = DateTime(2026, 9, 6, 3);

    final first = PendingVoiceDiceIntent(
      matchId: binding.matchId,
      playerId: binding.playerId,
      turnId: binding.turnId,
      requestedValue: 6,
      recognizedAt: baseTime,
      expiresAt: baseTime.add(const Duration(seconds: 3)),
    );
    final revised = PendingVoiceDiceIntent(
      matchId: binding.matchId,
      playerId: binding.playerId,
      turnId: binding.turnId,
      requestedValue: 5,
      recognizedAt: baseTime.add(const Duration(milliseconds: 40)),
      expiresAt: baseTime.add(const Duration(seconds: 3)),
    );

    expect(engine.acceptVoiceDiceIntent(first, now: baseTime), isTrue);
    expect(
      engine.acceptVoiceDiceIntent(
        revised,
        now: baseTime.add(const Duration(milliseconds: 40)),
      ),
      isFalse,
    );
    expect(engine.pendingVoiceDiceIntent, same(first));

    final roll = engine.reserveDiceRoll(
      randomDice: () => 2,
      now: baseTime.add(const Duration(milliseconds: 60)),
    );

    expect(roll, isNotNull);
    expect(roll!.source, DiceRollSource.voice);
    expect(roll.value, 6);
  });
}
