import 'package:flutter/foundation.dart';

@immutable
class TurnBinding {
  const TurnBinding({
    required this.matchId,
    required this.playerId,
    required this.turnId,
  });

  final String matchId;
  final String playerId;
  final int turnId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurnBinding &&
          other.matchId == matchId &&
          other.playerId == playerId &&
          other.turnId == turnId;

  @override
  int get hashCode => Object.hash(matchId, playerId, turnId);
}

@immutable
class PendingVoiceDiceIntent {
  const PendingVoiceDiceIntent({
    required this.matchId,
    required this.playerId,
    required this.turnId,
    required this.requestedValue,
    required this.recognizedAt,
    required this.expiresAt,
    this.consumed = false,
  }) : assert(requestedValue >= 1 && requestedValue <= 6);

  final String matchId;
  final String playerId;
  final int turnId;
  final int requestedValue;
  final DateTime recognizedAt;
  final DateTime expiresAt;
  final bool consumed;

  bool matches(TurnBinding binding) =>
      matchId == binding.matchId &&
      playerId == binding.playerId &&
      turnId == binding.turnId;

  bool isExpiredAt(DateTime time) => !time.isBefore(expiresAt);

  PendingVoiceDiceIntent markConsumed() => PendingVoiceDiceIntent(
        matchId: matchId,
        playerId: playerId,
        turnId: turnId,
        requestedValue: requestedValue,
        recognizedAt: recognizedAt,
        expiresAt: expiresAt,
        consumed: true,
      );
}

enum DiceRollSource { random, voice }

/// A resolved roll is also the commit capability for that exact roll.
///
/// Deliberately keep identity equality here. Two objects with identical visible
/// fields are still distinct roll events, and a stale/reconstructed callback
/// must never be able to impersonate the engine's currently active roll.
@immutable
class DiceRollResult {
  const DiceRollResult({
    required this.value,
    required this.source,
    required this.matchId,
    required this.playerId,
    required this.turnId,
    required this.resolvedAt,
  }) : assert(value >= 1 && value <= 6);

  final int value;
  final DiceRollSource source;
  final String matchId;
  final String playerId;
  final int turnId;
  final DateTime resolvedAt;

  TurnBinding get binding => TurnBinding(
        matchId: matchId,
        playerId: playerId,
        turnId: turnId,
      );
}
