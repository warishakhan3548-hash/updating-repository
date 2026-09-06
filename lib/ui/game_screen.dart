import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/ludo_engine.dart';
import '../services/voice_dice_controller.dart';
import 'game_palette.dart';
import 'ludo_board.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key, required this.playerCount});

  final int playerCount;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final LudoEngine _engine;
  late final VoiceDiceController _voice;
  late final AnimationController _diceController;
  late final AnimationController _celebrationController;
  final math.Random _random = math.Random();

  int _targetDice = 1;
  int _animationSeed = 1;
  int _handledVoiceIntentSerial = 0;
  bool _rollActionBusy = false;
  bool _winnerDialogShown = false;
  bool _appLifecycleActive = true;
  bool _modalVoicePause = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engine = LudoEngine(playerCount: widget.playerCount);
    _voice = VoiceDiceController(engine: _engine)..addListener(_handleVoiceFeedback);
    _diceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 560),
    );
    _celebrationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    unawaited(_voice.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleActive = state == AppLifecycleState.resumed;
    unawaited(
      _voice.setLifecycleActive(_appLifecycleActive && !_modalVoicePause),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voice.removeListener(_handleVoiceFeedback);
    _diceController.dispose();
    _celebrationController.dispose();
    _voice.dispose();
    _engine.dispose();
    super.dispose();
  }

  void _handleVoiceFeedback() {
    final serial = _voice.acceptedIntentSerial;
    final value = _voice.lastAcceptedValue;
    if (serial <= _handledVoiceIntentSerial || value == null) return;

    _handledVoiceIntentSerial = serial;
    HapticFeedback.selectionClick();
    SystemSound.play(SystemSoundType.click);

    // Do not roll re-entrantly from inside ChangeNotifier.notifyListeners().
    // The microtask is effectively immediate, while keeping notifier traversal
    // clean. The engine's synchronous reservation remains the race authority.
    scheduleMicrotask(() {
      if (!mounted ||
          _rollActionBusy ||
          !_engine.canRoll ||
          _voice.pendingValue == null) {
        return;
      }
      unawaited(_rollDice());
    });
  }

  Future<void> _rollDice() async {
    if (_rollActionBusy || !_engine.canRoll) return;
    _rollActionBusy = true;

    try {
      // VoiceDiceController reserves the authoritative logical roll before it
      // pauses the native recognizer. Keep that exact capability object all the
      // way through animation instead of reducing it to an integer, otherwise
      // a stale/reconstructed callback could bypass the engine's identity gate.
      final reservedValue = _voice.suspendForRoll();
      if (!mounted || !_engine.canRoll) {
        await _voice.resumeAfterRoll();
        return;
      }

      final reservation = _engine.reservedRollResult;
      if (reservation == null || reservedValue != reservation.value) {
        _engine.cancelRolling();
        await _voice.resumeAfterRoll();
        return;
      }

      final target = reservation.value;
      _targetDice = target;
      _animationSeed = _random.nextInt(5000);
      _engine.beginRolling();

      // beginRolling() must promote this exact reservation into the active
      // commit capability. Fail closed if anything invalidated/replaced it.
      if (!identical(_engine.activeRollResult, reservation)) {
        _engine.cancelRolling();
        await _voice.resumeAfterRoll();
        return;
      }

      HapticFeedback.selectionClick();

      try {
        await _diceController.forward(from: 0);
        if (!mounted) return;

        final committed = _engine.commitResolvedRoll(reservation);
        if (!committed) {
          _engine.cancelRolling();
          await _voice.resumeAfterRoll();
          return;
        }

        if (target == 6) {
          HapticFeedback.heavyImpact();
        } else {
          HapticFeedback.mediumImpact();
        }

        if (!_engine.awaitingMove) {
          await _voice.resumeAfterRoll();
        }
      } catch (_) {
        _engine.cancelRolling();
        await _voice.resumeAfterRoll();
      }
    } finally {
      _rollActionBusy = false;
    }
  }

  Future<void> _moveToken(int tokenId) async {
    final outcome = _engine.moveToken(tokenId);
    if (outcome == null) return;

    if (outcome.captures > 0) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.click);
    } else if (outcome.finishedToken) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }

    if (_engine.gameOver) {
      _showWinnerDialog();
      return;
    }

    // The move/turn transition above is already authoritative. Resume the
    // recognizer immediately instead of creating a 330 ms blind window in
    // which the next player can speak before Android is listening again.
    await _voice.resumeAfterRoll();
  }

  void _showWinnerDialog() {
    if (_winnerDialogShown || !mounted || _engine.winnerOrder.isEmpty) return;
    _winnerDialogShown = true;
    final ranking = List<LudoColor>.unmodifiable(_engine.winnerOrder);
    unawaited(_celebrationController.forward(from: 0));

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Game result',
      barrierColor: Colors.black.withValues(alpha: .78),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (dialogContext, _, __) {
        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _celebrationController,
                    builder: (context, _) => CustomPaint(
                      painter: _ConfettiPainter(
                        progress: _celebrationController.value,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(22),
                    child: Center(
                      child: _WinnerCard(
                        ranking: ranking,
                        onExit: () {
                          Navigator.of(dialogContext).pop();
                          Navigator.of(context).pop();
                        },
                        onPlayAgain: () {
                          Navigator.of(dialogContext).pop();
                          setState(() {
                            _winnerDialogShown = false;
                            _targetDice = 1;
                          });
                          _celebrationController.reset();
                          _engine.reset(widget.playerCount);
                          _voice.clearPending();
                          unawaited(_voice.resumeAfterRoll());
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: .88, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Engine changes rebuild the board and turn UI. Voice partials are isolated
    // inside their own AnimatedBuilders below so rapid recognition updates do
    // not rebuild the expensive board subtree.
    return AnimatedBuilder(
      animation: _engine,
      builder: (context, _) {
        final activeColor = GamePalette.player(_engine.currentColor);
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                Icon(Icons.casino_rounded, color: activeColor, size: 23),
                const SizedBox(width: 8),
                const Flexible(
                  child: Text(
                    'Aarish Kingdom',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GamePalette.textPrimary,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Restart game',
                onPressed: _engine.isRolling || _rollActionBusy
                    ? null
                    : () => _confirmRestart(context),
                icon: const Icon(Icons.refresh_rounded),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: DecoratedBox(
            decoration: const BoxDecoration(gradient: GamePalette.appBackground),
            child: Stack(
              children: [
                Positioned(
                  top: -110,
                  right: -80,
                  child: _AmbientOrb(
                    color: activeColor.withValues(alpha: .10),
                    size: 290,
                  ),
                ),
                const Positioned(
                  bottom: -100,
                  left: -90,
                  child: _AmbientOrb(
                    color: Color(0x164DD8FF),
                    size: 280,
                  ),
                ),
                SafeArea(
                  top: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 860;
                      return SingleChildScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.fromLTRB(
                          wide ? 22 : 12,
                          8,
                          wide ? 22 : 12,
                          28,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1120),
                            child: wide
                                ? _buildWideLayout(context)
                                : _buildPhoneLayout(context),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhoneLayout(BuildContext context) {
    return Column(
      children: [
        _buildTurnHeader(context),
        const SizedBox(height: 11),
        _buildBoardCard(),
        const SizedBox(height: 12),
        _buildVoicePanel(),
        const SizedBox(height: 12),
        _buildDicePanel(),
        const SizedBox(height: 12),
        _buildPlayersPanel(),
      ],
    );
  }

  Widget _buildWideLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            children: [
              _buildTurnHeader(context),
              const SizedBox(height: 13),
              _buildBoardCard(),
            ],
          ),
        ),
        const SizedBox(width: 20),
        SizedBox(
          width: 350,
          child: Column(
            children: [
              _buildVoicePanel(),
              const SizedBox(height: 13),
              _buildDicePanel(vertical: true),
              const SizedBox(height: 13),
              _buildPlayersPanel(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBoardCard() {
    final activeColor = GamePalette.player(_engine.currentColor);
    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        width: double.infinity,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: activeColor.withValues(alpha: .72), width: 2),
          boxShadow: [
            BoxShadow(
              color: activeColor.withValues(alpha: .18),
              blurRadius: 30,
              spreadRadius: 1,
              offset: const Offset(0, 14),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: .38),
              blurRadius: 34,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: LudoBoard(engine: _engine, onTokenTap: _moveToken),
      ),
    );
  }

  Widget _buildTurnHeader(BuildContext context) {
    final color = GamePalette.player(_engine.currentColor);
    final roll = _engine.currentRoll;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: GamePalette.surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .38)),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: .08), blurRadius: 18),
        ],
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: .3), blurRadius: 14),
              ],
            ),
            child: Text(
              _engine.currentColor.label.substring(0, 1),
              style: TextStyle(
                color: _onPlayerColor(_engine.currentColor),
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${_engine.currentColor.label} Turn',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: GamePalette.textPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '#${_engine.turnNumber}',
                        style: const TextStyle(
                          color: GamePalette.textMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, .15),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: Text(
                    _engine.lastEvent,
                    key: ValueKey<String>(_engine.lastEvent),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: GamePalette.textMuted,
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (roll != null) ...[
            const SizedBox(width: 9),
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Text(
                '$roll',
                style: TextStyle(
                  color: _onPlayerColor(_engine.currentColor),
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlayersPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: GamePalette.surface.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: .055)),
      ),
      child: Row(
        children: [
          for (var index = 0; index < _engine.players.length; index++) ...[
            if (index > 0) const SizedBox(width: 7),
            Expanded(child: _buildPlayerCard(index)),
          ],
        ],
      ),
    );
  }

  Widget _buildPlayerCard(int index) {
    final player = _engine.players[index];
    final active = index == _engine.currentPlayerIndex && !_engine.gameOver;
    final color = GamePalette.player(player.color);
    final homeCount = player.tokens.where((token) => token.finished).length;
    final inPlayCount =
        player.tokens.where((token) => !token.inYard && !token.finished).length;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: .14) : GamePalette.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active ? color : Colors.white.withValues(alpha: .04),
          width: active ? 1.4 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: active
                  ? [BoxShadow(color: color.withValues(alpha: .45), blurRadius: 9)]
                  : null,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            player.color.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? GamePalette.textPrimary : GamePalette.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$homeCount🏠 · $inPlayCount▶',
              maxLines: 1,
              style: const TextStyle(
                color: GamePalette.textMuted,
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoicePanel() {
    return AnimatedBuilder(
      animation: _voice,
      builder: (context, _) => _buildVoicePanelContent(),
    );
  }

  Widget _buildVoicePanelContent() {
    final pending = _voice.pendingValue;
    final movePaused = _engine.isRolling || _engine.awaitingMove || _rollActionBusy;
    final listening = _voice.listening && !movePaused;
    final accent = pending != null ? GamePalette.violet : GamePalette.green;

    final status = _voice.initializing
        ? 'Starting voice engine…'
        : !_voice.initialized
            ? 'Starting voice engine…'
            : !_voice.available
                ? 'Voice recognition unavailable'
                : !_voice.enabled
                    ? 'Voice control is off'
                    : movePaused
                        ? 'Voice safely paused for this move'
                        : listening
                            ? 'Listening… बोलो 1 से 6'
                            : 'Preparing microphone…';

    final detail = _voice.errorMessage ??
        (listening
            ? 'Hindi + Hinglish + English • say one dice value'
            : 'Voice automatically re-arms throughout the match');

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: GamePalette.surface.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: accent.withValues(alpha: pending != null ? .55 : .22),
        ),
        boxShadow: pending == null
            ? null
            : [
                BoxShadow(
                  color: GamePalette.violet.withValues(alpha: .14),
                  blurRadius: 20,
                ),
              ],
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: _voice.enabled ? 'Turn voice control off' : 'Turn voice control on',
            child: Material(
              color: _voice.enabled && _voice.available
                  ? accent.withValues(alpha: .18)
                  : GamePalette.surfaceRaised,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => unawaited(_voice.setEnabled(!_voice.enabled)),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _voice.enabled && _voice.available
                          ? accent.withValues(alpha: .6)
                          : Colors.white10,
                    ),
                    boxShadow: listening
                        ? [
                            BoxShadow(
                              color: GamePalette.green.withValues(alpha: .25),
                              blurRadius: 14,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    _voice.enabled ? Icons.mic_rounded : Icons.mic_off_rounded,
                    color: _voice.enabled && _voice.available
                        ? accent
                        : GamePalette.textMuted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: listening ? GamePalette.green : GamePalette.textMuted,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: GamePalette.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GamePalette.textMuted,
                    fontSize: 10.8,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Container(
              key: ValueKey<int?>(pending),
              width: 58,
              height: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: pending == null
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [GamePalette.violet, Color(0xFF6548F4)],
                      ),
                color: pending == null ? GamePalette.surfaceRaised : null,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(
                  color: pending == null ? Colors.white10 : Colors.white24,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    pending?.toString() ?? '—',
                    style: TextStyle(
                      color: pending == null ? GamePalette.textMuted : Colors.white,
                      fontSize: 25,
                      height: 1,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (pending != null)
                    const Text(
                      'VOICE',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 7.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .5,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDicePanel({bool vertical = false}) {
    return AnimatedBuilder(
      animation: _voice,
      builder: (context, _) => _buildDicePanelContent(vertical: vertical),
    );
  }

  Widget _buildDicePanelContent({required bool vertical}) {
    final canRoll = _engine.canRoll && !_rollActionBusy;
    final activeColor = GamePalette.player(_engine.currentColor);
    final pending = _voice.pendingValue;

    final dice = AnimatedBuilder(
      animation: _diceController,
      builder: (context, child) {
        final t = _diceController.value;
        final displayValue = _engine.isRolling && t < .91
            ? ((_animationSeed + (t * 43).floor()) % 6) + 1
            : (_engine.currentRoll ?? _targetDice);
        final angle = _engine.isRolling ? t * math.pi * 5.2 : 0.0;
        final scale = _engine.isRolling ? 1 + math.sin(t * math.pi) * .08 : 1.0;
        return Transform.scale(
          scale: scale,
          child: Transform.rotate(
            angle: angle,
            child: _DiceFace(value: displayValue, color: activeColor),
          ),
        );
      },
    );

    final info = Column(
      crossAxisAlignment:
          vertical ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(
            _engine.awaitingMove
                ? 'Choose a glowing token'
                : pending != null
                    ? 'Voice heard: $pending'
                    : 'Ready to roll',
            key: ValueKey<String>(
              '${_engine.awaitingMove}-$pending-${_engine.isRolling}',
            ),
            textAlign: vertical ? TextAlign.center : TextAlign.start,
            style: const TextStyle(
              color: GamePalette.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _engine.awaitingMove
              ? 'Tap the highlighted token on the board.'
              : pending != null
                  ? '$pending recognized — rolling automatically…'
                  : 'Say 1–6 to roll instantly, or tap for a random roll.',
          textAlign: vertical ? TextAlign.center : TextAlign.start,
          style: const TextStyle(
            color: GamePalette.textMuted,
            fontSize: 11,
            height: 1.3,
          ),
        ),
      ],
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: GamePalette.surface.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: activeColor.withValues(alpha: .22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .24),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackControls = vertical || constraints.maxWidth < 360;
          if (stackControls) {
            return Column(
              children: [
                Semantics(
                  button: true,
                  enabled: canRoll,
                  label: 'Roll dice',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: canRoll ? _rollDice : null,
                    child: dice,
                  ),
                ),
                const SizedBox(height: 13),
                info,
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: _rollButton(canRoll, activeColor),
                ),
              ],
            );
          }

          return Row(
            children: [
              Semantics(
                button: true,
                enabled: canRoll,
                label: 'Roll dice',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: canRoll ? _rollDice : null,
                  child: dice,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(child: info),
              const SizedBox(width: 10),
              SizedBox(
                height: 54,
                child: _rollButton(canRoll, activeColor),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _rollButton(bool canRoll, Color color) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: _onPlayerColor(_engine.currentColor),
        disabledBackgroundColor: GamePalette.surfaceRaised,
        disabledForegroundColor: GamePalette.textMuted,
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      onPressed: canRoll ? _rollDice : null,
      icon: _engine.isRolling
          ? const SizedBox(
              width: 17,
              height: 17,
              child: CircularProgressIndicator(strokeWidth: 2.1),
            )
          : const Icon(Icons.casino_rounded),
      label: Text(
        _engine.isRolling ? 'ROLLING' : 'ROLL',
        style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: .3),
      ),
    );
  }

  Future<void> _confirmRestart(BuildContext context) async {
    if (_modalVoicePause) return;
    _modalVoicePause = true;
    await _voice.setLifecycleActive(false);

    bool? restart;
    try {
      restart = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GamePalette.surface,
          title: const Text(
            'Restart game?',
            style: TextStyle(
              color: GamePalette.textPrimary,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: const Text(
            'All token positions and the current ranking will reset.',
            style: TextStyle(color: GamePalette.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('RESTART'),
            ),
          ],
        ),
      );
    } finally {
      _modalVoicePause = false;
      if (mounted) {
        await _voice.setLifecycleActive(_appLifecycleActive);
      }
    }

    if (restart != true || !mounted) return;
    _engine.reset(widget.playerCount);
    _voice.clearPending();
    await _voice.resumeAfterRoll();
  }

  Color _onPlayerColor(LudoColor color) =>
      color == LudoColor.yellow ? const Color(0xFF332A00) : Colors.white;
}

class _DiceFace extends StatelessWidget {
  const _DiceFace({required this.value, required this.color});

  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const positions = <Alignment>[
      Alignment(-.58, -.58),
      Alignment(0, -.58),
      Alignment(.58, -.58),
      Alignment(-.58, 0),
      Alignment.center,
      Alignment(.58, 0),
      Alignment(-.58, .58),
      Alignment(0, .58),
      Alignment(.58, .58),
    ];

    final dots = switch (value) {
      1 => <int>[4],
      2 => <int>[0, 8],
      3 => <int>[0, 4, 8],
      4 => <int>[0, 2, 6, 8],
      5 => <int>[0, 2, 4, 6, 8],
      _ => <int>[0, 2, 3, 5, 6, 8],
    };

    final dark = Color.lerp(color, Colors.black, .18)!;
    return Container(
      width: 82,
      height: 82,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color.lerp(color, Colors.white, .08)!, dark],
        ),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: Colors.white.withValues(alpha: .28),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: .3),
            blurRadius: 18,
            offset: const Offset(0, 9),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: .26),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            left: 11,
            top: 8,
            right: 11,
            height: 20,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: .16),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          for (final index in dots)
            Align(
              alignment: positions[index],
              child: Container(
                width: 10.5,
                height: 10.5,
                decoration: BoxDecoration(
                  color: color == GamePalette.yellow
                      ? const Color(0xFF392F00)
                      : Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WinnerCard extends StatelessWidget {
  const _WinnerCard({
    required this.ranking,
    required this.onExit,
    required this.onPlayAgain,
  });

  final List<LudoColor> ranking;
  final VoidCallback onExit;
  final VoidCallback onPlayAgain;

  @override
  Widget build(BuildContext context) {
    final winner = ranking.first;
    final winnerColor = GamePalette.player(winner);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
        decoration: BoxDecoration(
          color: GamePalette.surface,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: winnerColor.withValues(alpha: .55)),
          boxShadow: [
            BoxShadow(
              color: winnerColor.withValues(alpha: .25),
              blurRadius: 40,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: winnerColor.withValues(alpha: .16),
                shape: BoxShape.circle,
                border: Border.all(color: winnerColor.withValues(alpha: .55)),
              ),
              child: const Text('🏆', style: TextStyle(fontSize: 48)),
            ),
            const SizedBox(height: 15),
            Text(
              '${winner.label} wins!',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: GamePalette.textPrimary,
                fontSize: 25,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Aarish Kingdom champion of this round 🎉',
              textAlign: TextAlign.center,
              style: TextStyle(color: GamePalette.textMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: GamePalette.surfaceRaised,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < ranking.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Text(
                            i == 0
                                ? '🥇'
                                : i == 1
                                    ? '🥈'
                                    : i == 2
                                        ? '🥉'
                                        : '🏁',
                            style: const TextStyle(fontSize: 18),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            width: 13,
                            height: 13,
                            decoration: BoxDecoration(
                              color: GamePalette.player(ranking[i]),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ranking[i].label,
                              style: const TextStyle(
                                color: GamePalette.textPrimary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 285;
                final exit = OutlinedButton(
                  onPressed: onExit,
                  child: const Text('EXIT'),
                );
                final playAgain = FilledButton.icon(
                  onPressed: onPlayAgain,
                  icon: const Icon(Icons.replay_rounded),
                  label: const Text(
                    'PLAY AGAIN',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                );

                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      playAgain,
                      const SizedBox(height: 9),
                      exit,
                    ],
                  );
                }

                return Row(
                  children: [
                    Expanded(child: exit),
                    const SizedBox(width: 10),
                    Expanded(flex: 2, child: playAgain),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({required this.progress});

  final double progress;

  static const List<Color> _colors = <Color>[
    GamePalette.red,
    GamePalette.green,
    GamePalette.yellow,
    GamePalette.blue,
    GamePalette.violet,
    GamePalette.cyan,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 58; i++) {
      final seedX = ((i * 37) % 101) / 101;
      final seedY = ((i * 61) % 97) / 97;
      final drift = math.sin(progress * math.pi * 2 + i) * 18;
      final x = seedX * size.width + drift;
      final y = ((seedY + progress * (1.05 + (i % 4) * .07)) % 1.16) *
              (size.height + 80) -
          40;
      final color = _colors[i % _colors.length];
      final angle = progress * math.pi * (3 + i % 5) + i;
      final width = 5.0 + (i % 4) * 1.4;
      final height = 9.0 + (i % 3) * 2.0;

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: width, height: height),
          const Radius.circular(2),
        ),
        Paint()..color = color.withValues(alpha: .9),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _AmbientOrb extends StatelessWidget {
  const _AmbientOrb({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color,
              blurRadius: size * .45,
              spreadRadius: size * .05,
            ),
          ],
        ),
      ),
    );
  }
}
