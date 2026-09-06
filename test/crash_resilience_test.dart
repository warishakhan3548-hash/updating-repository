import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Voice reliability', () {
    test('native recognizer is single-instance guarded and continuously re-arms safely', () {
      final activity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(activity, contains('speechRecognizer?.let { return it }'));
      expect(activity, contains('SpeechRecognizer.createOnDeviceSpeechRecognizer'));
      expect(activity, contains('SpeechRecognizer.createSpeechRecognizer'));
      expect(activity, contains('destroyRecognizer()'));
      expect(activity, contains('speechRecognizer = null'));
      expect(activity, contains('scheduleRestart(resultRestartDelay())'));
      expect(activity, contains('scheduleRestart(restartDelayFor(error))'));
      expect(activity, contains('mainHandler.removeCallbacks(restartRunnable)'));
      expect(activity, contains('SpeechRecognizer.ERROR_RECOGNIZER_BUSY'));
      expect(activity, contains('override fun onPartialResults'));
      expect(activity, contains('override fun onResults'));
      expect(activity, contains('pausedByFlutter'));
      expect(activity, contains('activityResumed'));
      expect(activity, contains('restartDelayFor'));
      expect(activity, contains('coerceAtMost(4_000L)'));
      expect(
        activity,
        contains('armReadyWatchdog(objectEpoch, sessionEpoch, binding)'),
      );
      expect(
        activity,
        contains('armResultWatchdog(objectEpoch, sessionEpoch, binding)'),
      );
      expect(
        activity,
        contains('recycleStuckRecognizer(objectEpoch, sessionEpoch, binding)'),
      );
    });

    test('Android 13+ biases recognition toward the tiny dice vocabulary', () {
      final activity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(activity, contains('Build.VERSION_CODES.TIRAMISU'));
      expect(activity, contains('RecognizerIntent.EXTRA_BIASING_STRINGS'));
      expect(activity, contains('DICE_BIASING_STRINGS'));
      expect(activity, contains('"छक्का"'));
      expect(activity, contains('"छक्क"'));
      expect(activity, contains('"शक्का"'));
      expect(activity, contains('"पाँच"'));
      expect(activity, contains('"six"'));
      expect(activity, contains('SpeechRecognizer.CONFIDENCE_SCORES'));
      expect(activity, contains('"confidences" to confidences'));
      expect(activity, contains('isFinal = false'));
    });

    test('native speech cycles carry exact match/player/turn binding', () {
      final activity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();
      final controller =
          File('lib/services/voice_dice_controller.dart').readAsStringSync();
      final engine = File('lib/game/ludo_engine.dart').readAsStringSync();

      expect(activity, contains('data class VoiceBinding'));
      expect(activity, contains('recognitionBinding = binding'));
      expect(activity, contains('currentBinding == binding'));
      expect(activity, contains('"matchId" to binding.matchId'));
      expect(activity, contains('"playerId" to binding.playerId'));
      expect(activity, contains('"turnId" to binding.turnId'));
      expect(activity, contains('"recognizedAtMs" to System.currentTimeMillis()'));
      expect(controller, contains('eventBinding != currentBinding'));
      expect(engine, contains('intent.matches(voiceTurnBinding)'));
      expect(engine, contains('intent.isExpiredAt(clock)'));
      expect(engine, contains('if (_pendingVoiceDiceIntent != null) return false;'));
    });

    test('stale callbacks are invalidated by object and listening-session generations', () {
      final activity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(activity, contains('private var recognizerEpoch = 0L'));
      expect(activity, contains('private var recognitionSessionEpoch = 0L'));
      expect(activity, contains('val objectEpoch = recognizerEpoch'));
      expect(activity, contains('val sessionEpoch = recognitionSessionEpoch'));
      expect(activity, contains('isCurrentSession(objectEpoch, sessionEpoch, binding)'));
      expect(activity, contains('objectEpoch == recognizerEpoch'));
      expect(activity, contains('sessionEpoch == recognitionSessionEpoch'));
      expect(activity, contains('recognitionBinding == binding'));
      expect(activity, contains('currentBinding == binding'));
      expect(activity, contains('recognizerEpoch += 1L'));
      expect(activity, contains('recognitionSessionEpoch += 1L'));
      expect(activity, contains('restartForContextChange()'));
      expect(activity, contains('invalidateActiveSession(keepRecognizer = true)'));
      expect(activity, contains('"recognizerEpoch" to objectEpoch'));
      expect(activity, contains('"sessionEpoch" to sessionEpoch'));
    });

    test('roll pause invalidates the cycle while app pause fully releases native audio', () {
      final activity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(activity, contains('"pauseListening"'));
      expect(activity, contains('private fun pauseCurrentSession(keepWarm: Boolean)'));
      expect(activity, contains('pauseCurrentSession(keepWarm = true)'));
      expect(activity, contains('invalidateActiveSession(keepRecognizer = true)'));
      expect(activity, contains('recognizer.cancel()'));
      expect(activity, contains('override fun onPause()'));
      expect(activity, contains('pauseCurrentSession(keepWarm = false)'));
      expect(activity, contains('destroyRecognizer()'));
      expect(activity, contains('override fun onResume()'));
    });

    test('Dart event stream, auto-roll, and start calls are duplicate-guarded', () {
      final controller =
          File('lib/services/voice_dice_controller.dart').readAsStringSync();
      final gameScreen = File('lib/ui/game_screen.dart').readAsStringSync();

      expect(controller, contains('_eventSub ??='));
      expect(controller, contains('_starting ||'));
      expect(controller, contains('reserveDiceRoll'));
      expect(controller, contains('_rollSuspended = true'));
      expect(gameScreen, contains('_handledVoiceIntentSerial'));
      expect(gameScreen, contains('_voice.acceptedIntentSerial'));
      expect(gameScreen, contains('_rollActionBusy'));
      expect(gameScreen, contains('_voice.pendingValue == null'));
    });

    test('microphone permission prompt cannot be requested repeatedly in parallel', () {
      final activity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(activity, contains('permissionRequestInFlight'));
      expect(activity, contains('!permissionRequestInFlight'));
      expect(activity, contains('permissionRequestInFlight = true'));
      expect(activity, contains('permissionRequestInFlight = false'));
    });

    test('on-device language failure falls back once instead of restart-looping', () {
      final activity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(activity, contains('onDeviceRejectedForProcess'));
      expect(activity, contains('isLanguageAvailabilityError(error) && usingOnDeviceRecognizer'));
      expect(activity, contains('fallBackFromOnDeviceRecognizer()'));
      expect(activity, contains('"recoverable" to false'));
    });

    test('the old model extraction crash path is completely removed', () {
      final activity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();
      final controller =
          File('lib/services/voice_dice_controller.dart').readAsStringSync();

      expect(activity, isNot(contains('ZipInputStream')));
      expect(activity, isNot(contains('prepareOfflineVoskModel')));
      expect(activity, isNot(contains('MIN_VOSK_HEADROOM_MB')));
      expect(controller, isNot(contains('vosk_flutter_service')));
      expect(controller, isNot(contains('candidateFreshness')));
      expect(controller, isNot(contains('class VoiceDiceLatch')));
    });
  });
}
