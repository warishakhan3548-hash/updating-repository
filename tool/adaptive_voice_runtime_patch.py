from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> bool:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    if new in text:
        return False
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one anchor for {label} in {path}, found {count}."
        )
    file.write_text(text.replace(old, new, 1), encoding="utf-8")
    return True


changed: list[str] = []

controller = "lib/services/voice_dice_controller.dart"
old_suspend = """  Future<int?> suspendForRoll() async {
    if (_disposed) return null;
    final engine = _engine;
    final reservation = engine?.reserveDiceRoll(randomDice: _randomDice);
    if (engine != null && reservation == null) return null;
    _rollSuspended = true;
    _listening = false;
    _state = VoiceSessionState.paused;
    _safeNotify();
    if (_available && _enabled) {
      try {
        await _voiceChannel.invokeMethod<void>('pauseListening');
      } catch (_) {}
    }
    return reservation?.value;
  }
"""
new_suspend = """  /// Reserves the authoritative roll synchronously, then pauses native speech
  /// out-of-band. The engine reservation and [_rollSuspended] flag are the
  /// safety boundary, so dice animation must not wait on a platform-channel
  /// round trip before it can start. Any callback already in flight is rejected
  /// by the suspended flag / reserved-roll gate and cannot leak into a later turn.
  int? suspendForRoll() {
    if (_disposed) return null;
    final engine = _engine;
    final reservation = engine?.reserveDiceRoll(randomDice: _randomDice);
    if (engine != null && reservation == null) return null;
    _rollSuspended = true;
    _listening = false;
    _state = VoiceSessionState.paused;
    _safeNotify();
    if (_available && _enabled) {
      unawaited(_pauseNativeForRoll());
    }
    return reservation?.value;
  }

  Future<void> _pauseNativeForRoll() async {
    try {
      await _voiceChannel.invokeMethod<void>('pauseListening');
    } catch (_) {}
  }
"""
if replace_once(
    controller,
    old_suspend,
    new_suspend,
    "non-blocking roll reservation",
):
    changed.append("remove platform-channel pause latency from the dice commit hot path")

screen = "lib/ui/game_screen.dart"
if replace_once(
    screen,
    "      final reservedValue = await _voice.suspendForRoll();",
    "      final reservedValue = _voice.suspendForRoll();",
    "synchronous roll reservation call",
):
    changed.append("start dice animation without waiting for native recognizer cancellation")

native = "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt"
if replace_once(
    native,
    "    private var usingOnDeviceRecognizer = false\n    private var onDeviceRejectedForProcess = false\n",
    "    private var usingOnDeviceRecognizer = false\n    private var onDeviceRejectedForProcess = false\n    private var preferOnDeviceAfterProviderFailure = false\n",
    "adaptive provider state",
):
    changed.append("track temporary on-device failover preference")

old_provider_choice = """        val recognizer =
            if (SpeechRecognizer.isRecognitionAvailable(this)) {
                try {
                    usingOnDeviceRecognizer = false
                    SpeechRecognizer.createSpeechRecognizer(this)
                } catch (systemError: Throwable) {
                    createOnDeviceFallback(systemError)
                }
            } else {
                createOnDeviceFallback(null)
            } ?: return null
"""
new_provider_choice = """        val recognizer =
            if (preferOnDeviceAfterProviderFailure && isOnDeviceRecognitionUsable()) {
                try {
                    usingOnDeviceRecognizer = true
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
                } catch (onDeviceError: Throwable) {
                    // Do not get stuck retrying a provider that this process has
                    // already proved unusable. Return to the system recognizer.
                    preferOnDeviceAfterProviderFailure = false
                    onDeviceRejectedForProcess = true
                    if (SpeechRecognizer.isRecognitionAvailable(this)) {
                        try {
                            usingOnDeviceRecognizer = false
                            SpeechRecognizer.createSpeechRecognizer(this)
                        } catch (systemError: Throwable) {
                            emitRecognizerCreationFailure(systemError)
                            null
                        }
                    } else {
                        emitRecognizerCreationFailure(onDeviceError)
                        null
                    }
                }
            } else if (SpeechRecognizer.isRecognitionAvailable(this)) {
                try {
                    usingOnDeviceRecognizer = false
                    SpeechRecognizer.createSpeechRecognizer(this)
                } catch (systemError: Throwable) {
                    createOnDeviceFallback(systemError)
                }
            } else {
                createOnDeviceFallback(null)
            } ?: return null
"""
if replace_once(
    native,
    old_provider_choice,
    new_provider_choice,
    "adaptive recognizer selection",
):
    changed.append("keep accuracy-first system recognition while enabling deterministic on-device failover")

old_no_match_fallback = """                        onDeviceRejectedForProcess = true
                        destroyRecognizer()
"""
new_no_match_fallback = """                        onDeviceRejectedForProcess = true
                        preferOnDeviceAfterProviderFailure = false
                        destroyRecognizer()
"""
if replace_once(
    native,
    old_no_match_fallback,
    new_no_match_fallback,
    "return to system after repeated on-device no-match",
):
    changed.append("avoid oscillating back to a weak on-device model")

network_anchor = """                if (
                    error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY ||
                        error == SpeechRecognizer.ERROR_CLIENT
                ) {
"""
network_insertion = """                if (!usingOnDeviceRecognizer &&
                    (error == SpeechRecognizer.ERROR_NETWORK ||
                        error == SpeechRecognizer.ERROR_NETWORK_TIMEOUT ||
                        error == SpeechRecognizer.ERROR_SERVER) &&
                    isOnDeviceRecognitionUsable()
                ) {
                    // The default recognizer normally gives the best Hindi /
                    // Hinglish accuracy. When its provider or network is failing,
                    // switch this process to the local recognizer instead of
                    // repeatedly backing off on the same broken critical path.
                    preferOnDeviceAfterProviderFailure = true
                    destroyRecognizer()
                    emit(
                        mapOf(
                            "type" to "error",
                            "code" to error,
                            "recoverable" to true,
                            "message" to "Voice recognition switched to on-device recovery.",
                        ),
                    )
                    scheduleRestart(ON_DEVICE_FAILOVER_RESTART_MS)
                    return
                }

""" + network_anchor
if replace_once(
    native,
    network_anchor,
    network_insertion,
    "network/server provider failover",
):
    changed.append("fail over from network/server recognition failures to on-device speech")

if replace_once(
    native,
    "    private fun fallBackFromOnDeviceRecognizer() {\n        mainHandler.removeCallbacks(restartRunnable)\n        onDeviceRejectedForProcess = true\n",
    "    private fun fallBackFromOnDeviceRecognizer() {\n        mainHandler.removeCallbacks(restartRunnable)\n        onDeviceRejectedForProcess = true\n        preferOnDeviceAfterProviderFailure = false\n",
    "language fallback preference reset",
):
    changed.append("return permanently to system speech when the local language model is unavailable")

if replace_once(
    native,
    "        private const val SYSTEM_FALLBACK_RESTART_MS = 70L\n",
    "        private const val SYSTEM_FALLBACK_RESTART_MS = 70L\n        private const val ON_DEVICE_FAILOVER_RESTART_MS = 55L\n",
    "on-device failover restart constant",
):
    changed.append("add bounded low-latency provider failover restart")

android_test = "test/android_build_contract_test.dart"
if replace_once(
    android_test,
    "      expect(gameScreen, contains('unawaited(_rollDice())'));\n      expect(gameScreen, contains('_voice.pendingValue == null'));\n      expect(controller, contains('DiceVoiceIntentParser.isFastPartialCommand(heard)'));",
    "      expect(gameScreen, contains('unawaited(_rollDice())'));\n      expect(gameScreen, contains('_voice.pendingValue == null'));\n      expect(gameScreen, contains('final reservedValue = _voice.suspendForRoll();'));\n      expect(controller, contains('int? suspendForRoll()'));\n      expect(controller, contains('unawaited(_pauseNativeForRoll())'));\n      expect(controller, contains('DiceVoiceIntentParser.isFastPartialCommand(heard)'));",
    "non-blocking roll latency contract",
):
    changed.append("cover synchronous roll reservation / async native pause contract")

if replace_once(
    android_test,
    "      expect(mainActivity, contains('ON_DEVICE_NO_MATCH_FALLBACK_THRESHOLD = 2'));\n",
    "      expect(mainActivity, contains('ON_DEVICE_NO_MATCH_FALLBACK_THRESHOLD = 2'));\n      expect(mainActivity, contains('preferOnDeviceAfterProviderFailure'));\n      expect(mainActivity, contains('ON_DEVICE_FAILOVER_RESTART_MS'));\n      expect(mainActivity, contains('Voice recognition switched to on-device recovery.'));\n",
    "adaptive native provider contract",
):
    changed.append("cover network/server to on-device provider recovery")

pubspec = "pubspec.yaml"
if replace_once(
    pubspec,
    "version: 1.4.2+14",
    "version: 1.4.3+15",
    "release version bump",
):
    changed.append("bump Aarish Kingdom to 1.4.3+15")

if changed:
    print("Adaptive voice runtime upgrade applied:")
    for item in changed:
        print(f" - {item}")
else:
    print("Adaptive voice runtime upgrade already applied; no changes needed.")
