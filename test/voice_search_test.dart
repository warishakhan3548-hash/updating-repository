import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../lib/state/voice_search_controller.dart';

class FakeSpeech extends SpeechToText {
  FakeSpeech() : super.withMethodChannel();
  bool enabled = true, failLocales = false, announceStart = true;
  int starts = 0, cancels = 0, stops = 0;
  Completer<bool>? initialization;
  Completer<void>? starting;
  SpeechListenOptions? options;
  final results = <SpeechResultListener>[];
  final statuses = <SpeechStatusListener>[];
  final errors = <SpeechErrorListener>[];

  @override
  Future<bool> initialize({
    SpeechErrorListener? onError,
    SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<SpeechConfigOption>? options,
  }) async => initialization != null ? initialization!.future : enabled;
  @override
  Future<List<LocaleName>> locales() async {
    if (failLocales) throw StateError('device enumeration failed');
    return [
      LocaleName('en_IN', 'English (India)'),
      LocaleName('hi-IN', 'Hindi'),
      LocaleName('hi-IN', 'Hindi'),
    ];
  }

  @override
  Future<LocaleName?> systemLocale() async => LocaleName('hi-IN', 'Hindi');
  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> stop() async {
    stops++;
    statusListener?.call(SpeechToText.notListeningStatus);
  }

  @override
  Future<dynamic> listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    SpeechSoundLevelChange? onSoundLevelChange,
    dynamic cancelOnError = false,
    dynamic partialResults = true,
    dynamic onDevice = false,
    ListenMode listenMode = ListenMode.confirmation,
    dynamic sampleRate = 0,
    SpeechListenOptions? listenOptions,
  }) async {
    starts++;
    options = listenOptions;
    results.add(onResult!);
    statuses.add(statusListener!);
    errors.add(errorListener!);
    if (starting != null) await starting!.future;
    if (announceStart) statusListener?.call(SpeechToText.listeningStatus);
  }

  void result(String words, {bool finalResult = false, int? session}) {
    results[session ?? results.length - 1](
      SpeechRecognitionResult.fromJson({
        'alternates': [
          {'recognizedWords': words, 'confidence': .9},
        ],
        'resultType': finalResult ? 2 : 0,
      }),
    );
  }
}

void main() {
  Future<VoiceSearchController> ready(FakeSpeech speech) async {
    final voice = VoiceSearchController(speech: speech);
    addTearDown(() async {
      await voice.close();
      voice.dispose();
    });
    await voice.initialize();
    return voice;
  }

  test('uses device language IDs and default online/offline service', () async {
    final speech = FakeSpeech();
    final voice = await ready(speech);
    expect(voice.locales.length, 2);
    expect(voice.localeId, 'hi-IN');
    await voice.listen();
    expect(speech.options!.onDevice, false);
    expect(speech.options!.localeId, 'hi-IN');
    expect(voice.phase, VoicePhase.listening);
  });

  test('permission failure has a working retry', () async {
    final speech = FakeSpeech()..enabled = false;
    final voice = await ready(speech);
    expect(voice.phase, VoicePhase.unavailable);
    expect(voice.canListen, true);
    speech.enabled = true;
    await voice.listen();
    expect(speech.starts, 1);
    expect(voice.phase, VoicePhase.listening);
  });

  test(
    'locale enumeration failure keeps default recognition available',
    () async {
      final speech = FakeSpeech()..failLocales = true;
      final voice = await ready(speech);
      await voice.listen();
      expect(speech.options!.localeId, isNull);
      expect(voice.phase, VoicePhase.listening);
    },
  );

  test(
    'rapid taps cannot start two recognizers or change language mid-start',
    () async {
      final speech = FakeSpeech()..starting = Completer<void>();
      final voice = await ready(speech);
      final first = voice.listen();
      final second = voice.listen();
      voice.selectLanguage('en_IN');
      expect(voice.localeId, 'hi-IN');
      expect(voice.canSearch, false);
      speech.starting!.complete();
      await Future.wait([first, second]);
      expect(speech.starts, 1);
    },
  );

  test(
    'Stop preserves partial and accepts the complete final phrase',
    () async {
      final speech = FakeSpeech();
      final voice = await ready(speech);
      await voice.listen();
      speech.result('Dolo');
      await voice.stop();
      expect(voice.phase, VoicePhase.finishing);
      expect(voice.words, 'Dolo');
      expect(voice.canSearch, false);
      speech.result('Dolo 650 mg', finalResult: true);
      expect(voice.words, 'Dolo 650 mg');
      expect(voice.phase, VoicePhase.complete);
      expect(voice.canSearch, true);
    },
  );

  test(
    'previous session result, status and error cannot mutate a retry',
    () async {
      final speech = FakeSpeech();
      final voice = await ready(speech);
      await voice.listen();
      speech.result('Dolo', finalResult: true);
      await voice.listen();
      speech.result('new query');
      speech.result('stale query', session: 0);
      speech.statuses[0](SpeechToText.doneStatus);
      speech.errors[0](SpeechRecognitionError('error_permission', true));
      expect(voice.words, 'new query');
      expect(voice.phase, VoicePhase.listening);
      expect(voice.message, isEmpty);
    },
  );

  test(
    'silence is recoverable and does not erase a recognized phrase',
    () async {
      final speech = FakeSpeech();
      final voice = await ready(speech);
      await voice.listen();
      speech.result('Paracetamol');
      speech.errors.last(SpeechRecognitionError('error_speech_timeout', true));
      expect(voice.canListen, true);
      expect(voice.canSearch, true);
      expect(voice.words, 'Paracetamol');
      await voice.listen();
      expect(speech.starts, 2);
    },
  );

  test('background stops recording; resume waits for a new user tap', () async {
    final speech = FakeSpeech();
    final voice = await ready(speech);
    await voice.listen();
    speech.result('Dolo');
    voice.pause();
    speech.result('hidden words');
    expect(voice.words, 'Dolo');
    expect(voice.canListen, false);
    voice.resume();
    expect(speech.starts, 1);
    await voice.listen();
    expect(speech.starts, 2);
  });

  test('closing during initialization prevents later auto-start', () async {
    final speech = FakeSpeech()..initialization = Completer<bool>();
    final voice = VoiceSearchController(speech: speech);
    final initialize = voice.initialize(startListening: true);
    final closing = voice.close();
    speech.initialization!.complete(true);
    await Future.wait([initialize, closing]);
    expect(speech.starts, 0);
    expect(voice.phase, VoicePhase.closed);
    expect(speech.errorListener, isNull);
    voice.dispose();
  });

  test(
    'closing during startup cancels after startup and drops late callbacks',
    () async {
      final speech = FakeSpeech()..starting = Completer<void>();
      final voice = await ready(speech);
      final start = voice.listen();
      await Future<void>.delayed(Duration.zero);
      final close = voice.close();
      speech.starting!.complete();
      await Future.wait([start, close]);
      speech.result('late words');
      expect(voice.words, isEmpty);
      expect(voice.phase, VoicePhase.closed);
      expect(speech.cancels, greaterThanOrEqualTo(2));
      expect(speech.statusListener, isNull);
    },
  );

  testWidgets('silent startup failure times out into an actionable retry', (
    tester,
  ) async {
    final speech = FakeSpeech()..announceStart = false;
    final voice = VoiceSearchController(speech: speech);
    await voice.initialize();
    await voice.listen();
    expect(voice.phase, VoicePhase.starting);
    await tester.pump(const Duration(seconds: 6));
    expect(voice.phase, VoicePhase.ready);
    expect(voice.canListen, true);
    expect(voice.message, contains('could not start'));
    await voice.close();
    voice.dispose();
  });
}
