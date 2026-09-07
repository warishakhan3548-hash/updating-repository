import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'design.dart';

final _speech = SpeechToText();

Future<String?> voiceSearch(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _VoiceSheet(),
    );

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet();
  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> with WidgetsBindingObserver {
  String _words = '', _error = '', _locale = 'en_IN';
  bool _ready = false, _starting = false, _listening = false;
  int _generation = 0;
  List<LocaleName> _locales = [];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final enabled = await _speech.initialize(
        onError: (error) {
          if (mounted)
            setState(() {
              _error =
                  'Speech is unavailable: ${error.errorMsg}. You can type instead.';
              _listening = false;
            });
        },
        onStatus: (status) {
          if (mounted) setState(() => _listening = status == 'listening');
        },
      );
      _speech.errorListener = (error) {
        if (mounted)
          setState(() {
            _error =
                'Speech is unavailable: ${error.errorMsg}. You can type instead.';
            _listening = false;
          });
      };
      _speech.statusListener = (status) {
        if (mounted) setState(() => _listening = status == 'listening');
      };
      final locales = enabled ? await _speech.locales() : <LocaleName>[];
      if (!mounted) return;
      setState(() {
        _ready = enabled;
        _locales = locales
            .where(
              (l) => l.localeId.startsWith('en') || l.localeId.startsWith('hi'),
            )
            .toList();
        if (_locales.isEmpty) _locales = locales;
        if (_locales.isNotEmpty && !_locales.any((l) => l.localeId == _locale))
          _locale = _locales.first.localeId;
        if (!enabled) _error = 'Allow microphone access and enable a speech service in your phone settings.';
      });
    } catch (e) {
      if (mounted)
        setState(
          () => _error = 'Voice search could not start. Typing and scanning are still available.',
        );
    }
  }

  Future<void> _listen() async {
    if (!_ready || _starting) return;
    _starting = true;
    final generation = ++_generation;
    try {
      await _speech.cancel();
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = '';
        _words = '';
      });
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: _locale,
          listenFor: const Duration(seconds: 20),
          pauseFor: const Duration(seconds: 4),
          partialResults: true,
          onDevice: true,
          cancelOnError: true,
        ),
        onResult: (result) {
          if (mounted && generation == _generation)
            setState(() => _words = result.recognizedWords);
        },
      );
    } catch (e) {
      if (mounted)
        setState(
          () => _error = 'Speech recognition is unavailable for this language. Check the installed language pack.',
        );
    } finally {
      _starting = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      ++_generation;
      unawaited(_speech.cancel());
    }
  }

  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_speech.cancel());
    _speech.errorListener = null;
    _speech.statusListener = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Say the medicine name',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Include the strength if you know it. Offline availability depends on your phone’s installed speech service.',
            style: TextStyle(color: muted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          if (_locales.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: _locale,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Speech language'),
              items: _locales
                  .map(
                    (l) => DropdownMenuItem(
                      value: l.localeId,
                      child: Text(l.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: _listening
                  ? null
                  : (v) => setState(() => _locale = v!),
            ),
          const SizedBox(height: 20),
          Center(
            child: Icon(
              _listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
              size: 56,
              color: green,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              _words.isEmpty
                  ? (_listening ? 'Listening…' : 'Tap the microphone to begin')
                  : _words,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                _error,
                style: const TextStyle(color: red, fontSize: 12),
              ),
            ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: !_ready
                    ? null
                    : () async {
                        if (_listening) {
                          await _speech.stop();
                        } else {
                          await _listen();
                        }
                      },
                icon: Icon(_listening ? Icons.stop_rounded : Icons.mic_rounded),
                label: Text(_listening ? 'Stop' : 'Listen'),
              ),
              FilledButton.icon(
                onPressed: _words.trim().isEmpty
                    ? null
                    : () => Navigator.pop(context, _words),
                icon: const Icon(Icons.search_rounded),
                label: const Text('Search words'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
