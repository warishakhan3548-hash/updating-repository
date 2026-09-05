import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ludo_masti/game/dice_roll_models.dart';
import 'package:voice_ludo_masti/game/ludo_engine.dart';

void main() {
  test('only the exact active roll ticket can commit', () {
    final engine = LudoEngine(playerCount: 2);
    final resolvedAt = DateTime(2026, 9, 6, 2, 10);
    final active = engine.resolveDiceRoll(
      randomDice: () => 6,
      now: resolvedAt,
    )!;

    final forged = DiceRollResult(
      value: active.value,
      source: active.source,
      matchId: active.matchId,
      playerId: active.playerId,
      turnId: active.turnId,
      resolvedAt: active.resolvedAt,
    );

    expect(forged, isNot(same(active)));
    expect(engine.commitResolvedRoll(forged), isFalse);
    expect(engine.isRolling, isTrue);
    expect(engine.currentRoll, isNull);

    expect(engine.commitResolvedRoll(active), isTrue);
    expect(engine.isRolling, isFalse);
    expect(engine.currentRoll, 6);

    engine.dispose();
  });
}
