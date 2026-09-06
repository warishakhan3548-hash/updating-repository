import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android build contract', () {
    test('legacy Kotlin mode explicitly applies KGP before Flutter plugin', () {
      final properties = File('android/gradle.properties').readAsStringSync();
      final appGradle = File('android/app/build.gradle.kts').readAsStringSync();

      expect(properties, contains('android.builtInKotlin=false'));

      const kotlinPlugin = 'id("org.jetbrains.kotlin.android")';
      const flutterPlugin = 'id("dev.flutter.flutter-gradle-plugin")';
      final kotlinIndex = appGradle.indexOf(kotlinPlugin);
      final flutterIndex = appGradle.indexOf(flutterPlugin);

      expect(kotlinIndex, greaterThanOrEqualTo(0));
      expect(flutterIndex, greaterThan(kotlinIndex));
    });

    test('voice uses Android SpeechRecognizer instead of a bundled Vosk model', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final appGradle = File('android/app/build.gradle.kts').readAsStringSync();
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final mainActivity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(pubspec, isNot(contains('vosk_flutter_service')));
      expect(appGradle, isNot(contains('alphacephei.com/vosk')));
      expect(appGradle, isNot(contains('prepareOfflineVoiceModel')));
      expect(mainActivity, contains('SpeechRecognizer.createSpeechRecognizer'));
      expect(mainActivity, contains('RecognizerIntent.EXTRA_LANGUAGE'));
      expect(mainActivity, contains('private const val HINDI_LOCALE = "hi-IN"'));
      expect(mainActivity, contains('voice_ludo/speech'));
      expect(mainActivity, contains('voice_ludo/speech_events'));
      expect(mainActivity, contains('pauseListening'));
      expect(manifest, contains('android.permission.RECORD_AUDIO'));
      expect(manifest, contains('android.speech.RecognitionService'));
    });

    test('native speech bridge is match-scoped, latency-biased, and lifecycle-aware', () {
      final mainActivity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(mainActivity, contains('data class VoiceBinding'));
      expect(mainActivity, contains('"updateContext"'));
      expect(mainActivity, contains('currentBinding'));
      expect(mainActivity, contains('recognitionBinding'));
      expect(mainActivity, contains('"matchId" to binding.matchId'));
      expect(mainActivity, contains('"playerId" to binding.playerId'));
      expect(mainActivity, contains('"turnId" to binding.turnId'));
      expect(mainActivity, contains('"recognizedAtMs" to System.currentTimeMillis()'));
      expect(mainActivity, contains('"type" to "lifecycle"'));
      expect(mainActivity, contains('override fun onResume()'));
      expect(mainActivity, contains('override fun onPause()'));
      expect(mainActivity, contains('EXTRA_PREFER_OFFLINE'));
      expect(mainActivity, contains('EXTRA_PARTIAL_RESULTS'));
      expect(mainActivity, contains('EXTRA_BIASING_STRINGS'));
      expect(mainActivity, contains('DICE_BIASING_STRINGS'));
      expect(mainActivity, contains('SpeechRecognizer.CONFIDENCE_SCORES'));
      expect(mainActivity, contains('armReadyWatchdog(objectEpoch, sessionEpoch, binding)'));
      expect(mainActivity, contains('recycleStuckRecognizer'));
      expect(
        mainActivity,
        contains('EXTRA_PREFER_OFFLINE, usingOnDeviceRecognizer'),
      );
    });

    test('voice hot path is accuracy-first, bilingual, and low-latency', () {
      final mainActivity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      const system = 'SpeechRecognizer.createSpeechRecognizer(this)';
      const onDevice = 'SpeechRecognizer.createOnDeviceSpeechRecognizer(this)';

      expect(mainActivity, contains(system));
      expect(mainActivity, contains(onDevice));
      expect(mainActivity.indexOf(system), lessThan(mainActivity.indexOf(onDevice)));
      expect(mainActivity, contains('createOnDeviceFallback'));
      expect(mainActivity, contains('pauseCurrentSession(keepWarm = true)'));
      expect(mainActivity, contains('MAX_RESULTS = 20'));
      expect(mainActivity, contains('VOICE_LOCALES = listOf("hi-IN", "en-IN", "en-US")'));
      expect(mainActivity, contains('EXTRA_ENABLE_LANGUAGE_SWITCH'));
      expect(mainActivity, contains('EXTRA_ENABLE_LANGUAGE_DETECTION'));
      expect(mainActivity, contains('ON_DEVICE_NO_MATCH_FALLBACK_THRESHOLD = 2'));
      expect(
        mainActivity,
        isNot(contains('EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS')),
      );
      expect(
        mainActivity,
        isNot(contains('EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS')),
      );
      expect(mainActivity, contains('"छक्का छक्का"'));
      expect(mainActivity, contains('"पाँच पाँच"'));
      expect(mainActivity, contains('"six six"'));
      expect(mainActivity, contains('"शक्का"'));
      expect(mainActivity, contains('"छक्क"'));
      expect(mainActivity, contains('isFinal = false'));
    });

    test('accepted voice intent auto-rolls through the existing atomic roll path', () {
      final gameScreen = File('lib/ui/game_screen.dart').readAsStringSync();
      final controller =
          File('lib/services/voice_dice_controller.dart').readAsStringSync();

      expect(gameScreen, contains('VoiceDiceController(engine: _engine)'));
      expect(gameScreen, contains('_voice.acceptedIntentSerial'));
      expect(gameScreen, contains('scheduleMicrotask(()'));
      expect(gameScreen, contains('unawaited(_rollDice())'));
      expect(gameScreen, contains('_voice.pendingValue == null'));
      expect(controller, contains('DiceVoiceIntentParser.isFastPartialCommand(heard)'));
      expect(controller, contains('reserveDiceRoll'));
      expect(controller, contains('Duration(seconds: 3)'));
    });

    test('permission denial remains an optional voice failure, not a game dependency', () {
      final mainActivity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();
      final controller =
          File('lib/services/voice_dice_controller.dart').readAsStringSync();
      final engine = File('lib/game/ludo_engine.dart').readAsStringSync();

      expect(mainActivity, contains('SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS'));
      expect(mainActivity, contains('"type" to "permission"'));
      expect(controller, contains('bool _permissionDenied = false;'));
      expect(controller, contains('_permissionDenied = true;'));
      expect(controller, isNot(contains('_enabled = false;')));
      expect(controller, contains('_clearPendingIntent()'));
      expect(engine, contains('DiceRollSource.random'));
      expect(engine, contains('randomDice()'));
    });

    test('local bootstrap preserves the permanent Android speech bridge', () {
      final bootstrap = File('tool/bootstrap_android.sh').readAsStringSync();

      expect(bootstrap, isNot(contains('rm -rf android')));
      expect(bootstrap, isNot(contains('flutter create')));
      expect(bootstrap, contains('voice_ludo/speech'));
      expect(bootstrap, contains('SpeechRecognizer.createSpeechRecognizer'));
      expect(bootstrap, isNot(contains('alphacephei.com/vosk')));
    });

    test('turn boundaries invalidate listening sessions while keeping recognizer warm', () {
      final mainActivity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();

      expect(mainActivity, contains('private var recognizerEpoch = 0L'));
      expect(mainActivity, contains('private var recognitionSessionEpoch = 0L'));
      expect(mainActivity, contains('recognitionSessionEpoch += 1L'));
      expect(mainActivity, contains('recognizer.setRecognitionListener('));
      expect(
        mainActivity,
        contains('createRecognitionListener(objectEpoch, sessionEpoch, binding)'),
      );
      expect(mainActivity, contains('restartForContextChange()'));
      expect(mainActivity, contains('invalidateActiveSession(keepRecognizer = true)'));
      expect(mainActivity, contains('sessionEpoch == recognitionSessionEpoch'));
      expect(mainActivity, contains('recognitionBinding == binding'));
      expect(mainActivity, contains('currentBinding == binding'));
      expect(mainActivity, contains('"sessionEpoch" to sessionEpoch'));
      expect(mainActivity, isNot(contains('scheduleWarmStandby()')));
      expect(mainActivity, isNot(contains('WARM_STANDBY_DELAY_MS')));
    });

    test('native confidence metadata feeds the bounded Dart confidence fusion', () {
      final mainActivity = File(
        'android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt',
      ).readAsStringSync();
      final controller =
          File('lib/services/voice_dice_controller.dart').readAsStringSync();

      expect(mainActivity, contains('SpeechRecognizer.CONFIDENCE_SCORES'));
      expect(mainActivity, contains('"confidences" to confidences'));
      expect(controller, contains('_confidenceAt(confidenceValues, i)'));
      expect(controller, contains('recognitionConfidence'));
      expect(controller, contains('measuredConfidence < .30'));
    });

    test('premium voice UI hides raw transcripts and gates modal lifecycle', () {
      final gameScreen = File('lib/ui/game_screen.dart').readAsStringSync();
      final controller =
          File('lib/services/voice_dice_controller.dart').readAsStringSync();
      final setup = File('lib/ui/setup_screen.dart').readAsStringSync();
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

      expect(gameScreen, contains('WidgetsBindingObserver'));
      expect(gameScreen, contains('_modalVoicePause'));
      expect(gameScreen, contains('setLifecycleActive(false)'));
      expect(gameScreen, contains("'Aarish Kingdom'"));
      expect(gameScreen, isNot(contains('Heard: “')));
      expect(controller, contains("String get lastHeard => '';"));
      expect(
        controller,
        contains('if (values.any((value) => value != requestedValue))'),
      );
      expect(setup, contains('MATCH VOICE READY'));
      expect(setup, contains('Dice खुद roll होगा'));
      expect(setup, isNot(contains('OFFLINE VOICE AI')));
      expect(setup, isNot(contains('No internet needed while playing')));
      expect(manifest, contains('android:label="Aarish Kingdom"'));
    });
  });
}
