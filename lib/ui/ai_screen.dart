import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/ai_protocol.dart';
import '../domain/local_ai_protocol.dart';
import '../domain/medicine.dart';
import '../services/ai_service.dart';
import '../services/local_ai_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'local_models_panel.dart';
import 'medicine_capture.dart';
import 'medicine_intake_panel.dart';
import 'voice_sheet.dart';

const Color _aiPurple = Color(0xFF7857D8);
const Color _aiBlue = Color(0xFF397BFF);
const Color _aiMagenta = Color(0xFFB64FD2);

class AiScreen extends StatefulWidget {
  const AiScreen({super.key, required this.controller});

  final PharmacyController controller;

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  final _service = AiService();
  final _local = LocalAiService.instance;
  final _input = TextEditingController();
  final _request = TextEditingController();
  final _scroll = ScrollController();

  final List<_AiChatMessage> _messages = const [
    _AiChatMessage(
      'I can help manage Aaris Pharmacy inventory. Ask here with your connected AI, or open settings to share a pharmacy TXT with any external AI. Every proposed change is reviewed before it can be saved.',
      false,
    ),
  ].toList();

  AiConfiguration _configuration = const AiConfiguration();
  AiPlan? _plan;
  Set<int> _selected = {};
  String _error = '';
  bool _requesting = false;
  bool _preparingRequest = false;
  bool _sharing = false;
  bool _reviewing = false;
  bool _externalReady = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _local.initialize();
      final config = await _service.loadConfiguration();
      if (mounted) setState(() => _configuration = config);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    ++_generation;
    _service.cancel();
    if (widget.controller.aiPreparing) widget.controller.cancelAi();
    _input.dispose();
    _request.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _appendMessage(String text, bool user) {
    final clean = text.trim();
    if (!mounted || clean.isEmpty) return;
    setState(() => _messages.add(_AiChatMessage(clean, user)));
    _scrollToEnd();
  }

  Future<void> _openConnections() async {
    if (_requesting || _reviewing || widget.controller.aiPreparing) return;
    final result = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          _AiConnectionsSheet(initial: _configuration, service: _service),
    );
    if (!mounted || result == null) return;
    if (result == _AiConnectionsSheet.externalAction) {
      await _share();
      return;
    }
    if (result is AiConfiguration) {
      setState(() => _configuration = result);
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = '';
    });
    try {
      final data = widget.controller.export();
      await sharePharmacy(data);
      if (!mounted) return;
      setState(() {
        _externalReady = true;
        _messages.add(
          const _AiChatMessage(
            'Pharmacy TXT is ready and the AI prompt is copied. You can send it to an AI now, or save the TXT to Files/Drive and attach it manually later. When the AI finishes, copy its final pharmacy JSON and tap Paste & Review here.',
            false,
          ),
        );
      });
      _scrollToEnd();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<AiPlan?> _review({bool announce = true}) async {
    if (_reviewing || widget.controller.aiPreparing) return null;
    final input = _input.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Paste the complete pharmacy AI JSON first.');
      return null;
    }
    final generation = _generation;
    setState(() {
      _reviewing = true;
      _plan = null;
      _selected = {};
      _error = '';
    });
    try {
      final plan = await widget.controller.reviewAsync(input);
      if (!mounted ||
          generation != _generation ||
          _input.text.trim() != input) {
        return null;
      }
      setState(() {
        _plan = plan;
        _selected = {
          for (var i = 0; i < plan.changes.length; i++)
            if (plan.changes[i].possibleDuplicates.isEmpty &&
                !_requiresExplicitMutationSelection(plan.changes[i].operation))
              i,
        };
      });
      if (announce) {
        final reply = plan.reply.trim().isNotEmpty
            ? plan.reply.trim()
            : plan.changes.isEmpty
            ? 'The AI response is valid. No inventory change was proposed.'
            : '${plan.changes.length} proposed change${plan.changes.length == 1 ? '' : 's'} are ready for your review.';
        _appendMessage(reply, false);
      }
      _scrollToEnd();
      return plan;
    } catch (e) {
      if (mounted && generation == _generation && _input.text.trim() == input) {
        setState(() {
          _plan = null;
          _error = e.toString().replaceFirst('FormatException: ', '');
        });
      }
      return null;
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _reviewing = false);
      }
    }
  }

  Future<void> _ask() async {
    if (_preparingRequest ||
        _requesting ||
        _reviewing ||
        widget.controller.aiPreparing)
      return;
    final request = _request.text.trim();
    if (request.isEmpty) return;
    setState(() => _preparingRequest = true);
    try {
      await _local.initialize();
      if (!mounted) return;
      if (!_local.hasSelection && _configuration.key.isEmpty) {
        await _openConnections();
        if (!mounted || (!_local.hasSelection && _configuration.key.isEmpty))
          return;
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return;
    } finally {
      if (mounted) setState(() => _preparingRequest = false);
    }

    final generation = ++_generation;
    setState(() {
      _requesting = true;
      _error = '';
      _plan = null;
      _messages.add(_AiChatMessage(request, true));
      _request.clear();
    });
    _scrollToEnd();

    try {
      final result = await _service.ask(
        _configuration,
        widget.controller.export,
        request,
        localContext: LocalInventoryContext(
          records: widget.controller.records,
          sales: widget.controller.sales,
          revision: widget.controller.snapshot.revision,
          today: widget.controller.today,
        ),
        conversation: _messages
            .skip(_messages.length > 6 ? _messages.length - 6 : 0)
            .map((m) => '${m.user ? 'Owner' : 'Assistant'}: ${m.text}')
            .join('\n'),
      );
      if (!mounted || generation != _generation) return;
      _input.text = result;
      final plan = await _review(announce: false);
      if (!mounted || generation != _generation || plan == null) return;
      final reply = plan.reply.trim().isNotEmpty
          ? plan.reply.trim()
          : plan.changes.isEmpty
          ? 'Done. No inventory change is needed.'
          : '${plan.changes.length} proposed change${plan.changes.length == 1 ? '' : 's'} are ready below. Review them before saving.';
      _appendMessage(reply, false);
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = e is TimeoutException
              ? 'The AI took too long. No inventory changes were made.'
              : e.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _requesting = false);
      }
    }
  }

  bool _looksLikeAiResponse(String text) {
    final clean = text.trimLeft();
    return clean.startsWith('{') ||
        clean.startsWith('```') ||
        (clean.contains('aaris.pharmacy.v1') && clean.contains('actions'));
  }

  Future<void> _sendComposer() async {
    if (_requesting || _reviewing || widget.controller.aiPreparing) return;
    final text = _request.text.trim();
    if (text.isEmpty) return;
    if (!_looksLikeAiResponse(text)) {
      await _ask();
      return;
    }

    setState(() {
      _input.text = text;
      _request.clear();
      _externalReady = false;
      _messages.add(
        const _AiChatMessage('External AI response pasted for review.', true),
      );
      _error = '';
    });
    _scrollToEnd();
    await _review();
  }

  Future<void> _pasteExternalResponse() async {
    if (_requesting || _reviewing || widget.controller.aiPreparing) return;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = clipboard?.text?.trim() ?? '';
    if (!mounted) return;
    if (raw.isEmpty) {
      setState(
        () => _error = 'Clipboard is empty. Copy the final AI JSON first.',
      );
      return;
    }
    setState(() {
      _input.text = raw;
      _externalReady = false;
      _messages.add(
        const _AiChatMessage('External AI response pasted for review.', true),
      );
      _error = '';
    });
    _scrollToEnd();
    await _review();
  }

  Future<void> _apply() async {
    final plan = _plan;
    if (plan == null ||
        _selected.isEmpty ||
        _reviewing ||
        _requesting ||
        widget.controller.aiPreparing) {
      return;
    }
    final selected = Set<int>.of(_selected);
    try {
      await widget.controller.applyAi(plan, selected);
      if (!mounted) return;
      setState(() {
        _messages.add(
          _AiChatMessage(
            '${selected.length} reviewed change${selected.length == 1 ? '' : 's'} saved. All inventory views are updated.',
            false,
          ),
        );
        _plan = null;
        _input.clear();
        _selected = {};
        _error = '';
      });
      _scrollToEnd();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  void _cancelRequest() {
    if (!_requesting) return;
    ++_generation;
    _service.cancel();
    setState(() {
      _requesting = false;
      _messages.add(
        const _AiChatMessage(
          'AI request cancelled. No inventory changes were made.',
          false,
        ),
      );
    });
    _scrollToEnd();
  }

  Color _operationColor(String operation) => switch (operation) {
    'add' => green,
    'update' => primary,
    'remove' => red,
    'mark_sold' => amber,
    'set_quantity' => amber,
    'receive_stock' => green,
    'restock' => _aiPurple,
    'restore' => green,
    _ => muted,
  };

  Widget _reviewPanel(BuildContext context) {
    final plan = _plan;
    if (plan == null) return const SizedBox.shrink();
    if (plan.changes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Surface(
          color: primarySoft,
          child: const Row(
            children: [
              Icon(Icons.check_circle_outline_rounded, color: primary),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Answer only · no inventory changes to review.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Surface(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [_aiBlue, _aiPurple, _aiMagenta],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.fact_check_outlined,
                    color: Colors.white,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Review ${plan.changes.length} proposed change${plan.changes.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Nothing changes until you approve it.',
                        style: TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < plan.changes.length; i++)
              Container(
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(185),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: _operationColor(plan.changes[i].operation)
                        .withAlpha(45),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CheckboxListTile(
                      value: _selected.contains(i),
                      onChanged: widget.controller.aiPreparing
                          ? null
                          : (value) => setState(
                              () => value == true
                                  ? _selected.add(i)
                                  : _selected.remove(i),
                            ),
                      activeColor: _operationColor(plan.changes[i].operation),
                      title: Text(
                        plan.changes[i].title,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        _operationLabel(plan.changes[i].operation),
                        style: TextStyle(
                          color: _operationColor(plan.changes[i].operation),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ),
                    ),
                    if (plan.changes[i].possibleDuplicates.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
                        child: Text(
                          'Possible existing medicine. Check its expiry and location before adding separate stock.',
                          style: TextStyle(color: amber, fontSize: 11.5),
                        ),
                      ),
                    ExpansionTile(
                      dense: true,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                      title: const Text(
                        'See exact changes',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      children: [
                        for (final entry in plan.changes[i].differences.entries)
                          if (entry.key != 'id')
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '${_fieldLabel(entry.key)}\n${_value(entry.key, entry.value['before'])} → ${_value(entry.key, entry.value['after'])}',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: muted,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
            if (widget.controller.aiPreparing) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value:
                    widget.controller.preparedActions /
                    (plan.changes.isEmpty ? 1 : plan.changes.length),
              ),
              const SizedBox(height: 8),
              Text(
                'Prepared ${widget.controller.preparedActions} of ${plan.changes.length}. Saving is atomic.',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
              TextButton(
                onPressed: widget.controller.cancelAi,
                child: const Text('Cancel before saving'),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.controller.aiPreparing || _selected.isEmpty
                    ? null
                    : _apply,
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: Text('Apply ${_selected.length} selected changes'),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Unselected changes stay untouched. Removal, SOLD, restore and stock-quantity operations are never pre-selected.',
              style: TextStyle(fontSize: 10.5, color: muted),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, _local]),
    builder: (context, _) => Column(
      children: [
        _AiHubHeader(
          configured: _local.hasSelection || _configuration.key.isNotEmpty,
          onSettings: _openConnections,
        ),
        Expanded(
          child: ListView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            children: [
              if (_local.hasSelection)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'On-device AI · ${_local.activeLabel}\n${_local.status}',
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ),
              for (final message in _messages)
                _AiMessageBubble(message: message),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                  child: Surface(
                    color: errorSoft,
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: red,
                          size: 20,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: SelectableText(
                            _error,
                            style: const TextStyle(color: red, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_plan != null) _reviewPanel(context),
              MedicineIntakePanel(
                controller: widget.controller,
                onAsk: (evidence) {
                  _request.text =
                      'Explain only the captured identity, salt and expiry and check existing stock; do not add stock or give treatment advice. OCR DATA: '
                      '${evidence.length > 2200 ? evidence.substring(0, 2200) : evidence}';
                  unawaited(_ask());
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
        if (_externalReady)
          _ExternalAiReadyCard(
            onPaste: _pasteExternalResponse,
            onDismiss: () => setState(() => _externalReady = false),
          ),
        if (_requesting)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _cancelRequest,
                icon: const Icon(Icons.close_rounded, size: 17),
                label: const Text('Cancel AI request'),
              ),
            ),
          ),
        _AiComposer(
          controller: _request,
          busy:
              _preparingRequest ||
              _requesting ||
              _reviewing ||
              widget.controller.aiPreparing,
          onSend: _sendComposer,
          onCamera: () async {
            await openMedicineCapture(context, widget.controller);
            if (mounted) _scrollToEnd();
          },
          onMic: () async {
            final words = await voiceSearch(
              context,
              // This new Hub mic is on-device even before model settings have
              // finished loading. Never let an initialization race use network STT.
              offlineOnly: true,
              title: 'Speak to Aaris AI',
              actionLabel: 'Use message',
            );
            if (mounted && words != null) setState(() => _request.text = words);
          },
        ),
      ],
    ),
  );
}

class _AiHubHeader extends StatelessWidget {
  const _AiHubHeader({required this.configured, required this.onSettings});

  final bool configured;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 18, 10),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_aiBlue, _aiPurple, _aiMagenta],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withAlpha(125)),
              boxShadow: [
                BoxShadow(
                  color: _aiPurple.withAlpha(50),
                  blurRadius: 22,
                  spreadRadius: -5,
                  offset: const Offset(3, 8),
                ),
              ],
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
          ),
          const SizedBox(width: 13),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI Controller',
                  style: TextStyle(
                    color: ink,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.4,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Aaris Pharmacy AI Hub',
                  style: TextStyle(
                    color: muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onSettings,
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _aiPurple.withAlpha(16),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _aiPurple.withAlpha(55)),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(
                      Icons.settings_rounded,
                      color: _aiPurple,
                      size: 23,
                    ),
                    if (configured)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: green,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _AiChatMessage {
  const _AiChatMessage(this.text, this.user);

  final String text;
  final bool user;
}

class _AiMessageBubble extends StatelessWidget {
  const _AiMessageBubble({required this.message});

  final _AiChatMessage message;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: message.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .82,
        ),
        margin: const EdgeInsets.only(bottom: 11),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        decoration: BoxDecoration(
          gradient: message.user
              ? const LinearGradient(colors: [_aiBlue, Color(0xFF0056B3)])
              : null,
          color: message.user
              ? null
              : dark
              ? const Color(0xFF1C2230)
              : Colors.white.withAlpha(235),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(19),
            topRight: const Radius.circular(19),
            bottomLeft: Radius.circular(message.user ? 19 : 5),
            bottomRight: Radius.circular(message.user ? 5 : 19),
          ),
          border: message.user
              ? null
              : Border.all(color: _aiPurple.withAlpha(dark ? 35 : 18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(dark ? 45 : 15),
              blurRadius: 15,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: message.user ? Colors.white : ink,
            fontSize: 13.5,
            height: 1.45,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ExternalAiReadyCard extends StatelessWidget {
  const _ExternalAiReadyCard({required this.onPaste, required this.onDismiss});

  final VoidCallback onPaste;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 7),
    padding: const EdgeInsets.fromLTRB(13, 10, 6, 10),
    decoration: BoxDecoration(
      color: _aiPurple.withAlpha(14),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _aiPurple.withAlpha(48)),
      boxShadow: [
        BoxShadow(
          color: _aiPurple.withAlpha(24),
          blurRadius: 18,
          spreadRadius: -7,
          offset: const Offset(2, 6),
        ),
      ],
    ),
    child: Row(
      children: [
        const Icon(Icons.content_paste_go_rounded, color: _aiPurple, size: 22),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Waiting for Other AI',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900),
              ),
              SizedBox(height: 2),
              Text(
                'Copy its final JSON, then review here.',
                style: TextStyle(color: muted, fontSize: 10.5),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onPaste,
          child: const Text(
            'Paste & Review',
            style: TextStyle(color: _aiPurple, fontWeight: FontWeight.w900),
          ),
        ),
        IconButton(
          tooltip: 'Dismiss external AI session',
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded, size: 19),
        ),
      ],
    ),
  );
}

class _AiComposer extends StatelessWidget {
  const _AiComposer({
    required this.controller,
    required this.busy,
    required this.onSend,
    required this.onMic,
    required this.onCamera,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onMic;
  final VoidCallback onCamera;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
    child: Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(238),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _aiPurple.withAlpha(30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(18),
            blurRadius: 20,
            spreadRadius: -5,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Camera, rapid photos or video',
            onPressed: onCamera,
            icon: const Icon(Icons.camera_alt_outlined),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !busy,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: 'Ask AI or paste pharmacy JSON…',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 11,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Dictate Hindi or English message',
            onPressed: busy ? null : onMic,
            icon: const Icon(Icons.mic_none_rounded),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: busy ? null : onSend,
              borderRadius: BorderRadius.circular(24),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: busy
                        ? [muted.withAlpha(100), muted.withAlpha(70)]
                        : const [Color(0xFF4285F4), Color(0xFF9B72CB)],
                  ),
                  shape: BoxShape.circle,
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(13),
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(
                        Icons.arrow_upward_rounded,
                        color: Colors.white,
                      ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _AiConnectionsSheet extends StatefulWidget {
  const _AiConnectionsSheet({required this.initial, required this.service});

  static const String externalAction = 'external-ai';

  final AiConfiguration initial;
  final AiService service;

  @override
  State<_AiConnectionsSheet> createState() => _AiConnectionsSheetState();
}

class _AiConnectionsSheetState extends State<_AiConnectionsSheet> {
  late String provider;
  late final TextEditingController model;
  late final TextEditingController endpoint;
  late final TextEditingController key;
  bool obscure = true;
  bool busy = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    provider = widget.initial.provider;
    model = TextEditingController(text: widget.initial.model);
    endpoint = TextEditingController(text: widget.initial.endpoint);
    key = TextEditingController(text: widget.initial.key);
  }

  @override
  void dispose() {
    model.dispose();
    endpoint.dispose();
    key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final config = AiConfiguration(
        provider: provider,
        model: model.text.trim(),
        endpoint: endpoint.text.trim(),
        key: key.text.trim(),
      );
      await widget.service.saveConfiguration(config);
      if (mounted) Navigator.pop(context, config);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e.toString().replaceFirst('FormatException: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.service.forgetKey();
      if (mounted) Navigator.pop(context, const AiConfiguration());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .90,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFFF8FAFF),
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: muted.withAlpha(70),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const Text(
                'AI connections',
                style: TextStyle(
                  color: ink,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.4,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Use another AI without an API key, or connect your own provider inside Aaris Pharmacy.',
                style: TextStyle(color: muted, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 18),
              const LocalModelsPanel(),
              const SizedBox(height: 18),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: busy
                      ? null
                      : () => Navigator.pop(
                          context,
                          _AiConnectionsSheet.externalAction,
                        ),
                  borderRadius: BorderRadius.circular(22),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 96),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          _aiPurple.withAlpha(22),
                          const Color(0xFF4285F4).withAlpha(12),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: _aiPurple.withAlpha(75)),
                      boxShadow: [
                        BoxShadow(
                          color: _aiPurple.withAlpha(24),
                          blurRadius: 20,
                          spreadRadius: -7,
                          offset: const Offset(2, 7),
                        ),
                      ],
                    ),
                    child: const Row(
                      children: [
                        _ExternalAiIcon(),
                        SizedBox(width: 15),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Connect with Other AI',
                                style: TextStyle(
                                  color: _aiPurple,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -.2,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Send now, or save the TXT and attach it manually later',
                                style: TextStyle(
                                  color: muted,
                                  fontSize: 11.5,
                                  height: 1.35,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: _aiPurple,
                          size: 28,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(child: Divider(color: muted.withAlpha(50))),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: Text(
                      'OR',
                      style: TextStyle(
                        color: muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .8,
                      ),
                    ),
                  ),
                  Expanded(child: Divider(color: muted.withAlpha(50))),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                'Use AI inside the app',
                style: TextStyle(
                  color: ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Your API key stays in secure device storage and is never included in pharmacy exports.',
                style: TextStyle(color: muted, fontSize: 11.5, height: 1.4),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: provider,
                decoration: const InputDecoration(labelText: 'API format'),
                items: const [
                  DropdownMenuItem(
                    value: 'Gemini',
                    child: Text('Google Gemini'),
                  ),
                  DropdownMenuItem(
                    value: 'Compatible',
                    child: Text('OpenAI-compatible'),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => provider = value ?? 'Gemini'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: model,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Model name',
                  hintText: 'Enter a model available with your provider',
                ),
              ),
              if (provider == 'Compatible') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: endpoint,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Full HTTPS chat/completions endpoint',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: key,
                enabled: !busy,
                obscureText: obscure,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'API key',
                  suffixIcon: IconButton(
                    tooltip: obscure ? 'Show API key' : 'Hide API key',
                    onPressed: busy
                        ? null
                        : () => setState(() => obscure = !obscure),
                    icon: Icon(
                      obscure
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                  ),
                ),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error,
                    style: const TextStyle(color: red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: busy ? null : _save,
                  icon: const Icon(Icons.lock_rounded),
                  label: Text(busy ? 'Saving…' : 'Save AI setup'),
                ),
              ),
              if (widget.initial.key.isNotEmpty)
                Center(
                  child: TextButton(
                    onPressed: busy ? null : _remove,
                    child: const Text('Remove saved key'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExternalAiIcon extends StatelessWidget {
  const _ExternalAiIcon();

  @override
  Widget build(BuildContext context) => Container(
    width: 52,
    height: 52,
    decoration: BoxDecoration(
      color: _aiPurple.withAlpha(20),
      shape: BoxShape.circle,
      border: Border.all(color: _aiPurple.withAlpha(70)),
    ),
    child: const Icon(Icons.auto_awesome_rounded, color: _aiPurple, size: 27),
  );
}

bool _requiresExplicitMutationSelection(String operation) => const {
  'remove',
  'mark_sold',
  'restore',
  'set_quantity',
  'receive_stock',
}.contains(operation);

String _operationLabel(String operation) =>
    {
      'add': 'Add new stock',
      'update': 'Edit existing stock',
      'remove': 'Remove from inventory',
      'mark_sold': 'Mark out of stock · reorder',
      'set_quantity': 'Set exact counted quantity · review required',
      'receive_stock': 'Receive stock quantity · review required',
      'restock': 'Restock medicine',
      'restore': 'Restore removed stock',
    }[operation] ??
    operation;

String _fieldLabel(String key) =>
    {
      'unitPricePaise': 'Inventory unit cost',
      'soldUnitPricePaise': 'Cost when marked sold',
      'soldQuantity': 'Quantity when marked sold',
      'ocrText': 'Scanned text',
      'batchNumber': 'Batch / lot number',
      'mfg': 'Manufacturing date',
      'soldAt': 'Marked sold at',
      'archiveReason': 'Removal reason',
      'archivedAt': 'Removed at',
    }[key] ??
    key;

String _value(String key, dynamic value) => value == null || value == ''
    ? 'Not provided'
    : key.toLowerCase().contains('price') && value is int
    ? money(value)
    : '$value';
