import 'package:flutter/foundation.dart';

import 'dice_roll_models.dart';

enum LudoColor { red, green, yellow, blue }

extension LudoColorLogic on LudoColor {
  String get label => switch (this) {
        LudoColor.red => 'Red',
        LudoColor.green => 'Green',
        LudoColor.yellow => 'Yellow',
        LudoColor.blue => 'Blue',
      };

  int get startIndex => switch (this) {
        LudoColor.red => 0,
        LudoColor.green => 13,
        LudoColor.yellow => 26,
        LudoColor.blue => 39,
      };
}

class LudoToken {
  LudoToken(this.id);

  final int id;
  int progress = -1;

  bool get inYard => progress < 0;
  bool get finished => progress == LudoEngine.finishProgress;
}

class LudoPlayer {
  LudoPlayer(this.color)
      : tokens = List<LudoToken>.generate(4, (index) => LudoToken(index));

  final LudoColor color;
  final List<LudoToken> tokens;

  bool get finished => tokens.every((token) => token.finished);
}

class MoveOutcome {
  const MoveOutcome({
    required this.movedColor,
    required this.tokenId,
    required this.roll,
    required this.captures,
    required this.extraTurn,
    required this.finishedToken,
  });

  final LudoColor movedColor;
  final int tokenId;
  final int roll;
  final int captures;
  final bool extraTurn;
  final bool finishedToken;
}

class LudoEngine extends ChangeNotifier {
  LudoEngine({required int playerCount}) {
    _voiceRuntimeEngine = this;
    reset(playerCount);
  }

  static LudoEngine? _voiceRuntimeEngine;

  /// Compatibility bridge for the existing GameScreen construction order.
  /// VoiceDiceController captures this engine once at construction; it does not
  /// keep resolving a mutable global reference during gameplay.
  static LudoEngine? get voiceRuntimeEngine => _voiceRuntimeEngine;

  static const int finishProgress = 57;
  static const Set<int> safeGlobalCells = <int>{
    0,
    8,
    13,
    21,
    26,
    34,
    39,
    47,
  };

  late List<LudoPlayer> players;
  int _currentPlayerIndex = 0;
  bool isRolling = false;
  bool awaitingMove = false;
  bool gameOver = false;
  int? currentRoll;
  Set<int> movableTokenIds = <int>{};
  final List<LudoColor> winnerOrder = <LudoColor>[];
  String lastEvent = 'Say a number, then tap the dice.';
  int turnNumber = 1;

  int _matchGeneration = 0;
  late String _matchId;
  int _turnSequence = 1;
  PendingVoiceDiceIntent? _pendingVoiceDiceIntent;
  PendingVoiceDiceIntent? _lastConsumedVoiceIntent;
  DiceRollResult? _reservedRollResult;
  DiceRollResult? _activeRollResult;

  int get currentPlayerIndex => _currentPlayerIndex;
  LudoPlayer get currentPlayer => players[_currentPlayerIndex];
  LudoColor get currentColor => currentPlayer.color;
  String get matchId => _matchId;
  String get currentPlayerId => currentColor.name;
  int get turnSequence => _turnSequence;
  PendingVoiceDiceIntent? get pendingVoiceDiceIntent => _pendingVoiceDiceIntent;
  PendingVoiceDiceIntent? get lastConsumedVoiceIntent => _lastConsumedVoiceIntent;
  DiceRollResult? get reservedRollResult => _reservedRollResult;
  DiceRollResult? get activeRollResult => _activeRollResult;

  TurnBinding get voiceTurnBinding => TurnBinding(
        matchId: _matchId,
        playerId: currentPlayerId,
        turnId: _turnSequence,
      );

  bool get canRoll => !gameOver && !isRolling && !awaitingMove;

  void reset(int playerCount) {
    if (playerCount < 2 || playerCount > 4) {
      throw RangeError.range(playerCount, 2, 4, 'playerCount');
    }

    _voiceRuntimeEngine = this;
    final colors = switch (playerCount) {
      2 => <LudoColor>[LudoColor.red, LudoColor.yellow],
      3 => <LudoColor>[LudoColor.red, LudoColor.green, LudoColor.yellow],
      _ => LudoColor.values,
    };

    players = colors.map(LudoPlayer.new).toList(growable: false);
    _currentPlayerIndex = 0;
    isRolling = false;
    awaitingMove = false;
    gameOver = false;
    currentRoll = null;
    movableTokenIds = <int>{};
    winnerOrder.clear();
    turnNumber = 1;
    _matchGeneration += 1;
    _matchId = '${identityHashCode(this)}:$_matchGeneration';
    _turnSequence = 1;
    _pendingVoiceDiceIntent = null;
    _lastConsumedVoiceIntent = null;
    _reservedRollResult = null;
    _activeRollResult = null;
    lastEvent = '${currentPlayer.color.label} starts. Say 1–6 and roll!';
    notifyListeners();
  }

  bool acceptVoiceDiceIntent(
    PendingVoiceDiceIntent intent, {
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    if (!canRoll ||
        _reservedRollResult != null ||
        intent.consumed ||
        intent.isExpiredAt(clock)) {
      return false;
    }
    if (!intent.matches(voiceTurnBinding)) return false;

    final current = _pendingVoiceDiceIntent;
    if (current != null && current.recognizedAt.isAfter(intent.recognizedAt)) {
      // A delayed callback from the same turn must never replace a newer command.
      return false;
    }

    _pendingVoiceDiceIntent = intent;
    notifyListeners();
    return true;
  }

  void clearPendingVoiceIntent() {
    if (_pendingVoiceDiceIntent == null) return;
    _pendingVoiceDiceIntent = null;
    notifyListeners();
  }

  /// Freezes a roll value synchronously while preserving the existing UI's
  /// beginRolling/animation/commit sequence. Once reserved, new voice callbacks
  /// are rejected even though the visual dice animation has not started yet.
  DiceRollResult? reserveDiceRoll({
    required int Function() randomDice,
    DateTime? now,
  }) {
    if (!canRoll || _reservedRollResult != null) return null;

    final clock = now ?? DateTime.now();
    final binding = voiceTurnBinding;
    final pending = _pendingVoiceDiceIntent;

    late final int value;
    late final DiceRollSource source;

    if (pending != null &&
        !pending.consumed &&
        !pending.isExpiredAt(clock) &&
        pending.matches(binding)) {
      value = pending.requestedValue;
      source = DiceRollSource.voice;
      _lastConsumedVoiceIntent = pending.markConsumed();
      _pendingVoiceDiceIntent = null;
    } else {
      _pendingVoiceDiceIntent = null;
      value = randomDice();
      if (value < 1 || value > 6) {
        throw StateError('Random dice source returned invalid value $value.');
      }
      source = DiceRollSource.random;
    }

    final result = DiceRollResult(
      value: value,
      source: source,
      matchId: binding.matchId,
      playerId: binding.playerId,
      turnId: binding.turnId,
      resolvedAt: clock,
    );
    _reservedRollResult = result;
    notifyListeners();
    return result;
  }

  /// Fully atomic roll entry point for newer callers.
  DiceRollResult? resolveDiceRoll({
    required int Function() randomDice,
    DateTime? now,
  }) {
    final result = reserveDiceRoll(randomDice: randomDice, now: now);
    if (result == null) return null;
    beginRolling();
    return _activeRollResult;
  }

  void beginRolling() {
    if (!canRoll) return;

    final reserved = _reservedRollResult;
    if (reserved != null) {
      if (reserved.binding != voiceTurnBinding) {
        _reservedRollResult = null;
        return;
      }
      _activeRollResult = reserved;
      _reservedRollResult = null;
    } else {
      // Legacy non-voice callers are still supported, but any pending voice
      // command is discarded because they explicitly bypassed reservation.
      _pendingVoiceDiceIntent = null;
      _activeRollResult = null;
    }

    isRolling = true;
    lastEvent = '${currentColor.label} is rolling…';
    notifyListeners();
  }

  void cancelRolling() {
    if (!isRolling && _reservedRollResult == null) return;
    isRolling = false;
    _reservedRollResult = null;
    _activeRollResult = null;
    notifyListeners();
  }

  bool commitResolvedRoll(DiceRollResult result) {
    if (!isRolling || gameOver) return false;
    final active = _activeRollResult;
    if (active == null || active != result || result.binding != voiceTurnBinding) {
      return false;
    }
    _commitRollValue(result.value);
    return true;
  }

  void commitRoll(int value) {
    if (!isRolling || gameOver) return;
    final active = _activeRollResult;
    if (active != null && active.value != value) {
      throw StateError(
        'Logical dice result ${active.value} cannot be committed as $value.',
      );
    }
    _commitRollValue(value);
  }

  void _commitRollValue(int value) {
    if (value < 1 || value > 6) {
      throw ArgumentError.value(value, 'value', 'Dice value must be 1–6');
    }

    currentRoll = value;
    isRolling = false;
    _reservedRollResult = null;
    _activeRollResult = null;
    movableTokenIds = _legalMoves(currentPlayer, value).toSet();

    if (movableTokenIds.isEmpty) {
      awaitingMove = false;
      currentRoll = null;

      // Fun rule: a six always earns another roll, even if every possible
      // token is temporarily blocked by the exact-home rule. There is no
      // three-six penalty and no artificial streak limit.
      if (value == 6) {
        lastEvent = '${currentColor.label} rolled 6 — no legal move. 🎲 Roll again!';
        _openNextRollForSamePlayer();
      } else {
        lastEvent = '${currentColor.label} rolled $value — no legal move.';
        _advanceTurn();
      }
      notifyListeners();
      return;
    }

    awaitingMove = true;
    lastEvent = movableTokenIds.length == 1
        ? '${currentColor.label} rolled $value. Tap the glowing token.'
        : '${currentColor.label} rolled $value. Choose a glowing token.';
    notifyListeners();
  }

  MoveOutcome? moveToken(int tokenId) {
    if (!awaitingMove || gameOver || currentRoll == null) return null;
    if (!movableTokenIds.contains(tokenId)) return null;

    final player = currentPlayer;
    final token = player.tokens[tokenId];
    final roll = currentRoll!;

    if (token.inYard) {
      token.progress = 0;
    } else {
      token.progress += roll;
    }

    var captures = 0;
    final landedGlobalCell = globalCellFor(player.color, token.progress);
    if (landedGlobalCell != null &&
        !safeGlobalCells.contains(landedGlobalCell)) {
      for (final opponent in players) {
        if (opponent.color == player.color || opponent.finished) continue;
        for (final opponentToken in opponent.tokens) {
          final opponentCell =
              globalCellFor(opponent.color, opponentToken.progress);
          if (opponentCell == landedGlobalCell) {
            opponentToken.progress = -1;
            captures += 1;
          }
        }
      }
    }

    final finishedToken = token.finished;
    awaitingMove = false;
    movableTokenIds = <int>{};
    currentRoll = null;

    if (player.finished && !winnerOrder.contains(player.color)) {
      winnerOrder.add(player.color);
      lastEvent = '🏆 ${player.color.label} finished all four tokens!';
      _completeRankingIfNeeded();
    } else if (captures > 0) {
      lastEvent =
          '💥 ${player.color.label} captured $captures token${captures == 1 ? '' : 's'}!';
    } else if (finishedToken) {
      lastEvent = '🏠 ${player.color.label} brought a token home!';
    } else {
      lastEvent = '${player.color.label} moved $roll step${roll == 1 ? '' : 's'}.';
    }

    final earnedExtraTurn = !gameOver &&
        !player.finished &&
        (roll == 6 || captures > 0);

    final outcome = MoveOutcome(
      movedColor: player.color,
      tokenId: tokenId,
      roll: roll,
      captures: captures,
      extraTurn: earnedExtraTurn,
      finishedToken: finishedToken,
    );

    if (!gameOver) {
      if (earnedExtraTurn) {
        lastEvent += roll == 6
            ? ' 🎲 Six gives another turn.'
            : ' ⚡ Capture gives another turn.';
        _openNextRollForSamePlayer();
      } else {
        _advanceTurn();
      }
    }

    notifyListeners();
    return outcome;
  }

  List<int> _legalMoves(LudoPlayer player, int roll) {
    final legal = <int>[];
    for (final token in player.tokens) {
      if (_canMove(token, roll)) legal.add(token.id);
    }
    return legal;
  }

  bool _canMove(LudoToken token, int roll) {
    if (token.finished) return false;
    if (token.inYard) return roll == 6;
    return token.progress + roll <= finishProgress;
  }

  int? globalCellFor(LudoColor color, int progress) {
    if (progress < 0 || progress > 51) return null;
    return (color.startIndex + progress) % 52;
  }

  void _openNextRollForSamePlayer() {
    _turnSequence += 1;
    _pendingVoiceDiceIntent = null;
    _reservedRollResult = null;
    _activeRollResult = null;
  }

  void _advanceTurn() {
    if (gameOver) return;

    _pendingVoiceDiceIntent = null;
    _reservedRollResult = null;
    _activeRollResult = null;

    var attempts = 0;
    do {
      _currentPlayerIndex = (_currentPlayerIndex + 1) % players.length;
      attempts += 1;
    } while (winnerOrder.contains(currentPlayer.color) &&
        attempts < players.length);

    // Defensive invariant: if every player were somehow ranked without the
    // normal completion path, do not leave the engine in an infinite turn loop.
    if (winnerOrder.contains(currentPlayer.color)) {
      _completeRankingIfNeeded();
      return;
    }

    turnNumber += 1;
    _turnSequence += 1;
    lastEvent += ' ${currentColor.label}’s turn.';
  }

  void _completeRankingIfNeeded() {
    if (winnerOrder.length < players.length - 1) return;

    for (final player in players) {
      if (!winnerOrder.contains(player.color)) {
        winnerOrder.add(player.color);
      }
    }
    gameOver = true;
    isRolling = false;
    awaitingMove = false;
    currentRoll = null;
    movableTokenIds = <int>{};
    _pendingVoiceDiceIntent = null;
    _reservedRollResult = null;
    _activeRollResult = null;
    lastEvent = '🎉 Game finished! ${winnerOrder.first.label} wins!';
  }

  @override
  void dispose() {
    if (identical(_voiceRuntimeEngine, this)) {
      _voiceRuntimeEngine = null;
    }
    _pendingVoiceDiceIntent = null;
    _reservedRollResult = null;
    _activeRollResult = null;
    super.dispose();
  }
}
