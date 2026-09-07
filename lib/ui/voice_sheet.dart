import 'dart:async';

import 'package:flutter/material.dart';

import '../state/voice_search_controller.dart';
import 'design.dart';

bool _voiceOpen = false;

Future<String?> voiceSearch(BuildContext context) async {
  if (_voiceOpen) return null;
  _voiceOpen = true;
  final controller = VoiceSearchController();
  try {
    FocusManager.instance.primaryFocus?.unfocus();
    final navigator = Navigator.of(context);
    final route = ModalBottomSheetRoute<String>(
      builder: (_) => _VoiceSheet(controller: controller),
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
    );
    final result = await navigator.push(route);
    await controller.close();
    await route.completed;
    return result;
  } finally {
    await controller.close();
    controller.dispose();
    _voiceOpen = false;
  }
}

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet({required this.controller});
  final VoiceSearchController controller;
  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> with WidgetsBindingObserver {
  VoiceSearchController get voice => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(voice.initialize(startListening: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      voice.resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached ||
        (state == AppLifecycleState.inactive &&
            voice.phase != VoicePhase.initializing)) {
      // The initial permission dialog itself can temporarily make the app inactive.
      voice.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(voice.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: voice,
    builder: (context, _) {
      final listening = voice.phase == VoicePhase.listening;
      final status = switch (voice.phase) {
        VoicePhase.initializing => 'Getting the microphone ready…',
        VoicePhase.starting => 'Starting microphone…',
        VoicePhase.listening => 'Listening…',
        VoicePhase.finishing => 'Finishing your words…',
        VoicePhase.complete => 'Ready to search',
        VoicePhase.unavailable => 'Microphone needs attention',
        VoicePhase.paused => 'Voice paused',
        _ => 'Tap Listen to begin',
      };
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            4,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Voice search',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close voice search',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Say a medicine name and its strength.',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 20),
              if (voice.locales.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey(voice.localeId),
                  initialValue: voice.localeId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Speech language',
                  ),
                  items: voice.locales
                      .map(
                        (locale) => DropdownMenuItem(
                          value: locale.localeId,
                          child: Text(
                            locale.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: voice.canListen
                      ? (value) {
                          if (value != null) voice.selectLanguage(value);
                        }
                      : null,
                ),
              const SizedBox(height: 24),
              Center(
                child: DepthIcon(
                  listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
                  color: primary,
                  background: primarySoft,
                  size: 80,
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 16),
              if (voice.words.isNotEmpty)
                Surface(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    voice.words,
                    style: const TextStyle(
                      fontSize: 18,
                      color: ink,
                      height: 1.5,
                    ),
                  ),
                ),
              if (voice.message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    voice.message,
                    style: const TextStyle(
                      color: muted,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: voice.busy
                        ? null
                        : listening
                        ? voice.stop
                        : voice.canListen
                        ? voice.listen
                        : null,
                    icon: Icon(
                      listening ? Icons.stop_rounded : Icons.mic_rounded,
                    ),
                    label: Text(
                      listening
                          ? 'Stop'
                          : voice.phase == VoicePhase.unavailable
                          ? 'Try again'
                          : 'Listen',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: voice.canSearch
                        ? () => Navigator.pop(context, voice.words.trim())
                        : null,
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('Search medicines'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Uses your phone’s speech service, which may need internet. Review the words before searching.',
                style: TextStyle(color: muted, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
      );
    },
  );
}
