import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

// SpeechToText is a platform singleton. voiceSearch owns its lease until the
// modal's exit animation and asynchronous cleanup have both completed.
enum VoicePhase {
  initializing,
  ready,
  starting,
  listening,
  finishing,
  complete,
  unavailable,
  paused,
  closed,
}

class VoiceSearchController extends ChangeNotifier {
  VoiceSearchController({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  VoicePhase phase = VoicePhase.ready;
  String words = '', message = '';
  String? localeId;
  List<LocaleName> locales = [];
  bool _initialized = false, _foreground = true, _closed = false;
  int _generation = 0;
  Timer? _watchdog;
  Future<void> _operations = Future.value();
  Future<void>? _closing;

  bool get busy =>
      phase == VoicePhase.initializing ||
      phase == VoicePhase.starting ||
      phase == VoicePhase.finishing;
  bool get canListen =>
      !_closed && _foreground && !busy && phase != VoicePhase.listening;
  bool get canSearch =>
      !_closed &&
      words.trim().isNotEmpty &&
      !busy &&
      phase != VoicePhase.listening;
  bool _current(int generation) =>
      !_closed && _foreground && generation == _generation;

  Future<void> _serial(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.catchError((Object _) {});
    return result;
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  void _detach() {
    _speech.errorListener = null;
    _speech.statusListener = null;
  }

  Future<void> initialize({bool startListening = false}) async {
    if (!canListen) return;
    final generation = ++_generation;
    phase = VoicePhase.initializing;
    message = '';
    _changed();
    try {
      await _serial(() async {
        final enabled = await _speech.initialize();
        if (!_current(generation)) return;
        _initialized = enabled;
        if (!enabled) {
          phase = VoicePhase.unavailable;
          message = 'Allow microphone access in phone settings and enable a speech service, then tap Try again.';
          _changed();
          return;
        }
        // Locale enumeration can fail on a working recognizer. Its default
        // language still works; never disable the microphone just for that.
        try {
          final available = await _speech.locales();
          if (!_current(generation)) return;
          locales = {for (final locale in available) locale.localeId: locale}
              .values
              .toList();
          final system = await _speech.systemLocale();
          if (!_current(generation)) return;
          String normalized(String id) => id.replaceAll('-', '_').toLowerCase();
          final preferred = [
            if (localeId != null) normalized(localeId!),
            if (system != null) normalized(system.localeId),
            'en_in',
            'hi_in',
          ];
          localeId = null;
          for (final id in preferred) {
            final matches = locales.where(
              (locale) => normalized(locale.localeId) == id,
            );
            if (matches.isNotEmpty) {
              localeId = matches.first.localeId;
              break;
            }
          }
          localeId ??= locales.isEmpty ? null : locales.first.localeId;
        } catch (_) {
          if (!_current(generation)) return;
          locales = [];
          localeId = null;
        }
        phase = VoicePhase.ready;
        _changed();
      });
      if (_current(generation) && _initialized && startListening)
        await listen();
    } catch (_) {
      if (!_current(generation)) return;
      _initialized = false;
      phase = VoicePhase.unavailable;
      message = 'Voice search could not start. Check microphone permission and tap Try again.';
      _changed();
    }
  }

  void selectLanguage(String id) {
    if (!canListen || !locales.any((locale) => locale.localeId == id)) return;
    localeId = id;
    _changed();
  }

  Future<void> listen() async {
    if (!canListen) return;
    if (!_initialized) {
      await initialize(startListening: true);
      return;
    }
    final generation = ++_generation;
    phase = VoicePhase.starting;
    message = '';
    words = '';
    _watchdog?.cancel();
    _changed();
    try {
      await _serial(() async {
        if (!_current(generation)) return;
        _detach();
        await _speech.cancel();
        if (!_current(generation)) return;
        // initialize is cached by the plugin; attach this session explicitly.
        _speech.errorListener = (error) => _error(generation, error.errorMsg);
        _speech.statusListener = (status) => _status(generation, status);
        await _speech.listen(
          listenOptions: SpeechListenOptions(
            localeId: localeId,
            listenFor: const Duration(seconds: 20),
            pauseFor: const Duration(seconds: 4),
            partialResults: true,
            // Use the installed service's normal online/offline capability.
            onDevice: false,
            cancelOnError: false,
            listenMode: ListenMode.search,
          ),
          onResult: (result) {
            if (!_current(generation)) return;
            if (result.recognizedWords.trim().isNotEmpty)
              words = result.recognizedWords;
            if (result.finalResult) {
              _finish(generation);
            } else {
              if (phase == VoicePhase.starting) phase = VoicePhase.listening;
              _changed();
            }
          },
        );
        if (_current(generation) && phase == VoicePhase.starting) {
          // Some services return without starting or reporting an error.
          _watchdog = Timer(const Duration(seconds: 5), () {
            if (_current(generation) && phase == VoicePhase.starting)
              _error(generation, 'start_failed');
          });
        }
      });
    } catch (_) {
      if (_current(generation)) _error(generation, 'start_failed');
    }
  }

  void _status(int generation, String status) {
    if (!_current(generation)) return;
    if (status == SpeechToText.listeningStatus) {
      if (phase != VoicePhase.starting) return;
      _watchdog?.cancel();
      phase = VoicePhase.listening;
      _changed();
    } else if (status == SpeechToText.doneStatus) {
      _finish(generation);
    } else if (status == SpeechToText.notListeningStatus &&
        (phase == VoicePhase.listening || phase == VoicePhase.starting)) {
      _finishing(generation);
    }
  }

  void _finishing(int generation) {
    phase = VoicePhase.finishing;
    _watchdog?.cancel();
    // Keep the last partial and allow the service's final result to arrive.
    _watchdog = Timer(const Duration(seconds: 3), () => _finish(generation));
    _changed();
  }

  void _finish(int generation) {
    if (!_current(generation)) return;
    _watchdog?.cancel();
    ++_generation;
    _detach();
    phase = words.trim().isEmpty ? VoicePhase.ready : VoicePhase.complete;
    message = words.trim().isEmpty
        ? 'No speech heard. Tap Listen and try again.'
        : '';
    _changed();
    unawaited(_serial(_speech.cancel).catchError((Object _) {}));
  }

  Future<void> stop() async {
    if (_closed || phase != VoicePhase.listening) return;
    final generation = _generation;
    _finishing(generation);
    try {
      await _serial(() async {
        if (_current(generation)) await _speech.stop();
      });
    } catch (_) {
      _finish(generation);
    }
  }

  void _error(int generation, String code) {
    if (!_current(generation)) return;
    _watchdog?.cancel();
    ++_generation;
    _detach();
    final permission = code == 'error_permission';
    if (permission) _initialized = false;
    phase = permission ? VoicePhase.unavailable : VoicePhase.ready;
    message = switch (code) {
      'error_no_match' || 'error_speech_timeout' =>
        'No clear speech heard. Move closer and tap Listen again.',
      'error_permission' => 'Microphone access is off. Allow it in phone settings, then tap Try again.',
      'error_language_not_supported' || 'error_language_unavailable' => 'This language is unavailable. Choose another speech language and retry.',
      'error_network' ||
      'error_network_timeout' ||
      'error_server' ||
      'error_server_disconnected' => 'The speech service could not connect. Check internet or the installed speech language, then retry.',
      'error_busy' || 'error_too_many_requests' => 'The microphone is busy. Close other recording apps, then tap Listen again.',
      _ => 'The speech service could not start. Check microphone access and tap Listen again.',
    };
    _changed();
    unawaited(_serial(_speech.cancel).catchError((Object _) {}));
  }

  void pause() {
    if (_closed) return;
    _foreground = false;
    ++_generation;
    _watchdog?.cancel();
    _detach();
    phase = VoicePhase.paused;
    message = 'Voice paused. Tap Listen when you are ready.';
    _changed();
    unawaited(_serial(_speech.cancel).catchError((Object _) {}));
  }

  void resume() {
    if (_closed) return;
    _foreground = true;
    if (phase == VoicePhase.paused) {
      phase = VoicePhase.ready;
      _changed();
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    ++_generation;
    phase = VoicePhase.closed;
    _watchdog?.cancel();
    _detach();
    return _closing = _serial(_speech.cancel).catchError((Object _) {});
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
