import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../domain/ai_conversation.dart';
import '../domain/ai_protocol.dart';
import '../domain/local_ai_failure.dart';
import '../domain/local_ai_protocol.dart';
import '../domain/medicine.dart';
import '../services/ai_service.dart';
import '../services/local_ai_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'cloud_ai_connection_panel.dart';
import 'local_models_panel.dart';
import 'medicine_capture.dart';
import 'medicine_intake_panel.dart';
import 'voice_sheet.dart';

const Color _aiPurple = Color(0xFF7857D8);
const Color _aiBlue = Color(0xFF397BFF);
const Color _aiMagenta = Color(0xFFB64FD2);

enum AiHubQuickAction { sold, removed, stockSummary, add, delete, modify }

enum _AiJourneyState { idle, preparing, thinking, streaming, stopping }

class AiScreen extends StatefulWidget {
  const AiScreen({
    super.key,
    required this.controller,
    this.onLocalCommand,
    this.onQuickAction,
  });

  final PharmacyController controller;
  final Future<String?> Function(String command)? onLocalCommand;
  final Future<String?> Function(AiHubQuickAction action)? onQuickAction;

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  final _service = AiService();
  final _local = LocalAiService.instance;
  final _input = TextEditingController();
  final _request = TextEditingController();
  final _scroll = ScrollController();
  late Listenable _screenListenable;

  final List<_AiChatMessage> _messages = [];
  int _localHistoryStart = 0;
  String _localSessionNotice = '';

  AiConfiguration _configuration = const AiConfiguration();
  AiPlan? _plan;
  Set<int> _selected = {};
  String _error = '';
  String _streamingText = '';
  _AiJourneyState _journey = _AiJourneyState.idle;
  bool _localCommanding = false;
  bool _sharing = false;
  bool _reviewing = false;
  bool _externalReady = false;
  int _generation = 0;
  int _configurationGeneration = 0;
  bool _connectionsOpen = false;
  Timer? _streamPreviewTimer;
  bool _scrollScheduled = false;
  bool _followResponse = true;

  bool get _cancellableRequest =>
      _journey == _AiJourneyState.thinking ||
      _journey == _AiJourneyState.streaming;
  bool get _requesting =>
      _cancellableRequest || _journey == _AiJourneyState.stopping;
  bool get _preparingRequest => _journey == _AiJourneyState.preparing;

  bool get _hasAiRoute => _configuration.localBrainEnabled
      ? _local.hasSelection
      : _configuration.key.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _screenListenable = Listenable.merge([widget.controller, _local]);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AiScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _screenListenable = Listenable.merge([widget.controller, _local]);
    }
  }

  Future<void> _load({bool prepareLocal = true}) async {
    final generation = ++_configurationGeneration;
    try {
      final config = await _service.loadConfiguration();
      if (!mounted || generation != _configurationGeneration) return;
      setState(() => _configuration = config);
      // Publish saved routing before optional model work. A corrupt manifest
      // must leave the connections editor and deterministic commands usable.
      if (prepareLocal && config.localBrainEnabled) {
        await _service.preparePreferredLocalRoute();
        if (mounted && generation == _configurationGeneration) setState(() {});
      }
    } catch (e) {
      if (mounted && generation == _configurationGeneration) {
        setState(() => _error = _friendlyAiError(e));
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    _clearStreamPreview();
    _service.cancel();
    if (widget.controller.aiPreparing) widget.controller.cancelAi();
    _input.dispose();
    _request.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _clearStreamPreview() {
    _streamPreviewTimer?.cancel();
    _streamPreviewTimer = null;
  }

  Object _screenRebuildToken() {
    final controller = widget.controller;
    final localRoute = _configuration.localBrainEnabled
        ? (_local.hasSelection, _local.activeLabel, _local.status)
        : (false, '', '');
    return (
      controller.aiPreparing,
      controller.preparedActions,
      _plan == null ? null : controller.snapshot.revision,
      localRoute,
    );
  }

  void _scrollToEnd({bool force = false}) {
    if (force) _followResponse = true;
    if (!_followResponse || _scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_scroll.hasClients || !_followResponse) return;
      final target = _scroll.position.maxScrollExtent;
      if ((_scroll.offset - target).abs() > .5) {
        _scroll.jumpTo(target);
      }
    });
  }

  void _appendMessage(String text, bool user, {bool status = false}) {
    final clean = text.trim();
    if (!mounted || clean.isEmpty) return;
    setState(
      () => _messages.add(_AiChatMessage(clean, user, status: status)),
    );
    _scrollToEnd(force: user);
  }

  String _friendlyAiError(Object error) {
    if (error is LocalAiGenerationTimeout) return error.message!;
    if (error is TimeoutException) {
      return 'The AI took too long to answer. No inventory changes were made. You can safely try again.';
    }
    final raw = error
        .toString()
        .replaceFirst(RegExp(r'^(Exception|Bad state|StateError):\s*'), '')
        .trim();
    final lower = raw.toLowerCase();
    if (lower.contains('clientexception') ||
        lower.contains('socketexception') ||
        lower.contains('connection failed') ||
        lower.contains('connection closed') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection reset')) {
      return 'The AI connection was interrupted. No inventory changes were made. Check the network/model route and try again.';
    }
    return raw.isEmpty
        ? 'The AI request could not finish. No inventory changes were made.'
        : raw;
  }

  void _finishLiveAssistantReply(String text, int generation) {
    final clean = text.trim();
    if (!mounted || generation != _generation || clean.isEmpty) return;
    setState(() {
      _messages.add(_AiChatMessage(clean, false));
      _streamingText = '';
      _journey = _AiJourneyState.idle;
    });
    _scrollToEnd();
  }

  Future<void> _openConnections() async {
    if (_connectionsOpen || _requesting || _reviewing ||
        widget.controller.aiPreparing) return;
    _connectionsOpen = true;
    ++_configurationGeneration;
    try {
      // Read before opening so a fast first tap cannot edit an empty startup
      // snapshot or let an older startup read replace the newly saved route.
      AiConfiguration initial = _configuration;
      try {
        initial = await _service.loadConfiguration();
      } catch (_) {
        // A corrupt saved envelope still needs an accessible replacement editor.
      }
      if (!mounted) return;
      final result = await showModalBottomSheet<Object?>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (context) =>
            _AiConnectionsSheet(initial: initial, service: _service),
      );
      if (!mounted) return;
      await _load(prepareLocal: false);
      if (!mounted || result == null) return;
      if (result == _AiConnectionsSheet.externalAction) await _share();
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyAiError(e));
    } finally {
      _connectionsOpen = false;
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
            'Pharmacy TXT is ready and the AI prompt is copied. Attach both to your AI and chat normally about medicines, expiry or other questions. When you ask it to add or update stock, copy the change JSON it prepares and tap Paste & Review here.',
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
        _plan = plan.changes.isEmpty ? null : plan;
        _selected = {
          for (var i = 0; i < plan.changes.length; i++)
            if (plan.changes[i].possibleDuplicates.isEmpty &&
                !_requiresExplicitLifecycleSelection(plan.changes[i].operation))
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
        widget.controller.aiPreparing) {
      return;
    }
    final request = _request.text.trim();
    if (request.isEmpty) return;

    setState(() {
      _journey = _AiJourneyState.preparing;
      _error = '';
    });
    try {
      await _local.initialize();
      if (!mounted) return;
      if (!_hasAiRoute) {
        await _openConnections();
        if (!mounted) return;
        if (!_hasAiRoute) {
          setState(
            () => _error = 'Connect a Local AI model or API for reasoning requests. Add, Open, Delete, stock search and other deterministic Aaris Brain commands still work without AI.',
          );
          return;
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyAiError(e));
      return;
    } finally {
      if (mounted && _journey == _AiJourneyState.preparing) {
        setState(() => _journey = _AiJourneyState.idle);
      }
    }

    if (!mounted || !_hasAiRoute) return;
    final generation = ++_generation;
    final ownerMessageIndex = _messages.length;
    final rawStream = StringBuffer();
    setState(() {
      _journey = _AiJourneyState.thinking;
      _streamingText = '';
      _error = '';
      _plan = null;
      _messages.add(_AiChatMessage(request, true));
      _request.clear();
    });
    _scrollToEnd(force: true);

    try {
      final historyLimit = _configuration.localBrainEnabled ? 6 : 16;
      final recentStart = _messages.length > historyLimit
          ? _messages.length - historyLimit
          : 0;
      final historyStart =
          _configuration.localBrainEnabled && _localHistoryStart > recentStart
          ? _localHistoryStart
          : recentStart;
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
            .skip(historyStart)
            .map((m) => '${m.user ? 'Owner' : 'Assistant'}: ${m.text}')
            .join('\n'),
        onContextReset: () {
          if (!mounted || generation != _generation) return;
          setState(() {
            _localHistoryStart = ownerMessageIndex;
            _localSessionNotice = 'New local chat started automatically · your current question is kept. Earlier messages stay visible but are no longer sent to the local model.';
          });
        },
        onStreamStarted: () {
          if (!mounted || generation != _generation) return;
          if (_journey == _AiJourneyState.thinking) {
            setState(() => _journey = _AiJourneyState.streaming);
            _scrollToEnd();
          }
        },
        onStreamReset: () {
          if (!mounted || generation != _generation) return;
          rawStream.clear();
          _clearStreamPreview();
          setState(() {
            _journey = _AiJourneyState.thinking;
            _streamingText = '';
          });
          _scrollToEnd();
        },
        onDelta: (delta) {
          if (!mounted || generation != _generation || delta.isEmpty) return;
          rawStream.write(delta);
          // Batch provider/native token bursts into one preview update. Parsing
          // and rebuilding the conversation for every tiny token causes jank.
          _streamPreviewTimer ??= Timer(const Duration(milliseconds: 32), () {
            _streamPreviewTimer = null;
            if (!mounted || generation != _generation) return;
            final visible = aiConversationPreview(rawStream.toString());
            if (_streamingText == visible) return;
            setState(() {
              _journey = _AiJourneyState.streaming;
              _streamingText = visible;
            });
            _scrollToEnd();
          });
        },
      );
      if (!mounted || generation != _generation) return;

      _clearStreamPreview();
      final response = AiConversationResponse.parse(result);
      if (response.planJson == null) {
        _finishLiveAssistantReply(response.reply, generation);
        return;
      }

      setState(() {
        _journey = _AiJourneyState.thinking;
        _streamingText = '';
      });
      _input.text = response.planJson!;
      final plan = await _review(announce: false);
      if (!mounted || generation != _generation) return;
      if (plan == null) {
        if (_error.isEmpty) {
          setState(
            () => _error = 'The AI response arrived but could not be validated. Nothing was changed.',
          );
        }
        return;
      }
      final reply = plan.reply.trim().isNotEmpty
          ? plan.reply.trim()
          : plan.changes.isEmpty
          ? 'Done. No inventory change is needed.'
          : '${plan.changes.length} proposed change${plan.changes.length == 1 ? '' : 's'} are ready below. Review them before saving.';
      _finishLiveAssistantReply(reply, generation);
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = _friendlyAiError(e);
          _streamingText = '';
          _journey = _AiJourneyState.idle;
        });
      }
    } finally {
      if (generation == _generation) _clearStreamPreview();
      if (mounted &&
          generation == _generation &&
          (_journey == _AiJourneyState.thinking ||
              (_journey == _AiJourneyState.streaming &&
                  _streamingText.isEmpty))) {
        setState(() => _journey = _AiJourneyState.idle);
      }
    }
  }

  Future<void> _sendComposer() async {
    if (_localCommanding ||
        _preparingRequest ||
        _requesting ||
        _reviewing ||
        widget.controller.aiPreparing) {
      return;
    }
    final text = _request.text.trim();
    if (text.isEmpty) return;

    if ((text.startsWith('{') || text.contains('```')) &&
        containsAiConversationJson(text)) {
      setState(() {
        _request.clear();
      });
      await _receiveExternalResponse(text);
      return;
    }

    // A configured AI route owns every typed natural-language message. Do not
    // let deterministic App Brain verbs such as add/edit/delete intercept the
    // owner's conversation before Local AI or the selected cloud provider sees
    // it. Quick-action tiles remain explicit deterministic controls, and the
    // local command parser remains the offline fallback when no AI route exists.
    if (_hasAiRoute) {
      await _ask();
      return;
    }

    final localHandler = widget.onLocalCommand;
    if (localHandler != null) {
      String? localReply;
      setState(() {
        _localCommanding = true;
        _error = '';
      });
      try {
        localReply = await localHandler(text);
      } catch (error) {
        if (mounted) {
          setState(() => _error = _friendlyAiError(error));
        }
        return;
      } finally {
        if (mounted) setState(() => _localCommanding = false);
      }
      if (!mounted) return;
      if (localReply != null) {
        final reply = localReply.trim();
        setState(() {
          _request.clear();
          _messages.add(_AiChatMessage(text, true));
          if (reply.isNotEmpty) _messages.add(_AiChatMessage(reply, false));
        });
        _scrollToEnd();
        return;
      }
    }

    await _ask();
  }

  Future<void> _runQuickAction(AiHubQuickAction action) async {
    final handler = widget.onQuickAction;
    if (handler == null ||
        _localCommanding ||
        _preparingRequest ||
        _requesting ||
        _reviewing ||
        widget.controller.aiPreparing) {
      return;
    }
    setState(() {
      _localCommanding = true;
      _error = '';
    });
    try {
      final reply = await handler(action);
      if (!mounted || reply == null || reply.trim().isEmpty) return;
      _appendMessage(reply.trim(), false);
    } catch (error) {
      if (mounted) {
        setState(() => _error = _friendlyAiError(error));
      }
    } finally {
      if (mounted) setState(() => _localCommanding = false);
    }
  }

  Future<void> _pasteExternalResponse() async {
    if (_requesting || _reviewing || widget.controller.aiPreparing) return;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = clipboard?.text?.trim() ?? '';
    if (!mounted) return;
    if (raw.isEmpty) {
      setState(
        () => _error = 'Clipboard is empty. Ask the AI for your stock changes, then copy its JSON.',
      );
      return;
    }
    await _receiveExternalResponse(raw);
  }

  Future<void> _receiveExternalResponse(String raw) async {
    try {
      final response = AiConversationResponse.parse(raw);
      setState(() {
        _plan = null;
        _selected = {};
        _input.text = response.planJson ?? '';
        _error = '';
        if (response.planJson != null) _externalReady = false;
      });
      if (response.planJson == null) {
        _appendMessage(response.reply, false);
        return;
      }
      _appendMessage(
        'External AI response pasted for review.',
        false,
        status: true,
      );
      await _review();
    } catch (error) {
      if (mounted) {
        setState(() {
          _plan = null;
          _selected = {};
          _error = _friendlyAiError(error);
        });
      }
    }
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
    if (!_cancellableRequest) return;
    final cancellationGeneration = ++_generation;
    _clearStreamPreview();
    final drainingLocal = _service.cancel();
    setState(() {
      _journey = drainingLocal
          ? _AiJourneyState.stopping
          : _AiJourneyState.idle;
      _streamingText = '';
      _messages.add(
        _AiChatMessage(
          drainingLocal
              ? 'AI request cancelled. Aaris is safely finishing the current native step before the next Send. No inventory changes were made.'
              : 'AI request cancelled. No inventory changes were made.',
          false,
        ),
      );
    });
    _scrollToEnd();
    if (drainingLocal) {
      unawaited(_finishLocalCancellation(cancellationGeneration));
    }
  }

  Future<void> _finishLocalCancellation(int generation) async {
    while (mounted && generation == _generation && _local.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!mounted ||
        generation != _generation ||
        _journey != _AiJourneyState.stopping) {
      return;
    }
    setState(() => _journey = _AiJourneyState.idle);
    _scrollToEnd();
  }

  Color _operationColor(String operation) => switch (operation) {
    'add' => green,
    'update' => primary,
    'remove' => red,
    'mark_sold' => amber,
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

    final stalePlan =
        plan.baseRevision != widget.controller.snapshot.revision;

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
            if (stalePlan) ...[
              const SizedBox(height: 10),
              const Surface(
                color: warningSoft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, color: amber, size: 20),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'Inventory changed after this review. This proposal is read-only now; ask AI again or paste a fresh response before applying.',
                        style: TextStyle(
                          color: amber,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                      onChanged:
                          widget.controller.aiPreparing || stalePlan
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
                    (_selected.isEmpty ? 1 : _selected.length),
              ),
              const SizedBox(height: 8),
              Text(
                'Prepared ${widget.controller.preparedActions} of ${_selected.length} selected changes. Saving is atomic.',
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
                onPressed:
                    widget.controller.aiPreparing ||
                        stalePlan ||
                        _selected.isEmpty
                    ? null
                    : _apply,
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: Text('Apply ${_selected.length} selected changes'),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Unselected changes stay untouched. Remove, SOLD and Restore actions are never pre-selected.',
              style: TextStyle(fontSize: 10.5, color: muted),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ActiveListenableBuilder(
    listenable: _screenListenable,
    rebuildToken: _screenRebuildToken,
    builder: (context, _) {
      final busy =
          _localCommanding ||
          _preparingRequest ||
          _requesting ||
          _reviewing ||
          widget.controller.aiPreparing;
      return Column(
        children: [
          _AiHubHeader(configured: _hasAiRoute, onSettings: _openConnections),
          if (_configuration.localBrainEnabled && _local.hasSelection)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _configuration.key.isNotEmpty
                      ? 'Aaris Brain · On-device · ${_local.activeLabel} · Cloud connection saved'
                      : 'Aaris Brain · On-device · ${_local.activeLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: muted),
                ),
              ),
            )
          else if (_configuration.key.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'AI route · ${_configuration.provider} API',
                  style: const TextStyle(fontSize: 10.5, color: muted),
                ),
              ),
            ),
          if (_externalReady)
            _ExternalAiReadyCard(
              onPaste: _pasteExternalResponse,
              onDismiss: () => setState(() => _externalReady = false),
            ),
          if (_configuration.localBrainEnabled &&
              _localSessionNotice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text(
                _localSessionNotice,
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ),
          if (_cancellableRequest)
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
          Expanded(
            child: NotificationListener<UserScrollNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.direction != ScrollDirection.idle &&
                    _scroll.hasClients) {
                  _followResponse = _scroll.position.extentAfter <= 80;
                }
                return false;
              },
              child: CustomScrollView(
                controller: _scroll,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  // Historical chat can grow for the whole screen session while
                  // streamed replies update every few milliseconds. Materialize
                  // only rows near the viewport instead of rebuilding every old
                  // bubble on each preview tick.
                  if (_messages.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      sliver: SliverList.builder(
                        itemCount: _messages.length,
                        itemBuilder: (context, index) =>
                            _AiMessageBubble(message: _messages[index]),
                      ),
                    ),
                  // Keep the operational tail as its own eagerly-mounted sliver.
                  // MedicineIntakePanel owns live queue UI/state and must not be
                  // recycled merely because the pharmacist scrolls chat history.
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      _messages.isEmpty ? 4 : 0,
                      16,
                      14,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_journey == _AiJourneyState.thinking)
                            _AiThinkingBubble(
                              detail:
                                  _configuration.localBrainEnabled &&
                                      _local.hasSelection
                                  ? _local.status
                                  : 'AI route connected · preparing answer',
                            ),
                          if (_journey == _AiJourneyState.streaming &&
                              _streamingText.isEmpty)
                            const _AiThinkingBubble(
                              detail:
                                  'Receiving and validating streamed response…',
                            ),
                          if (_journey == _AiJourneyState.streaming &&
                              _streamingText.isNotEmpty)
                            _AiMessageBubble(
                              message: _AiChatMessage(_streamingText, false),
                            ),
                          if (_journey == _AiJourneyState.stopping)
                            const _AiThinkingBubble(
                              detail:
                                  'Stopping local inference safely · next Send unlocks when the native lease is free',
                            ),
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
                                        style: const TextStyle(
                                          color: red,
                                          fontSize: 12,
                                        ),
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
                  ),
                ],
              ),
            ),
          ),
          _AiQuickActions(
            busy: busy || widget.onQuickAction == null,
            onTap: _runQuickAction,
          ),
          _AiComposer(
            controller: _request,
            busy: busy,
            onSend: _sendComposer,
            onCamera: () async {
              await openMedicineCapture(context, widget.controller);
              if (mounted) _scrollToEnd();
            },
            onMic: () async {
              final words = await voiceSearch(
                context,
                offlineOnly: true,
                title: 'Speak to Aaris',
                actionLabel: 'Use message',
              );
              if (mounted && words != null) {
                setState(() => _request.text = words);
              }
            },
          ),
        ],
      );
    },
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
  const _AiChatMessage(this.text, this.user, {this.status = false});

  final String text;
  final bool user;
  final bool status;
}

class _AiThinkingBubble extends StatelessWidget {
  const _AiThinkingBubble({required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .82,
        ),
        margin: const EdgeInsets.only(bottom: 11),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1C2230) : Colors.white.withAlpha(235),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(19),
            topRight: Radius.circular(19),
            bottomLeft: Radius.circular(5),
            bottomRight: Radius.circular(19),
          ),
          border: Border.all(color: _aiPurple.withAlpha(dark ? 35 : 18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Thinking…',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 10.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiMessageBubble extends StatelessWidget {
  const _AiMessageBubble({required this.message});

  final _AiChatMessage message;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    if (message.status) {
      return Align(
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: _aiBlue.withAlpha(dark ? 24 : 12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _aiBlue.withAlpha(dark ? 55 : 32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.description_outlined,
                size: 15,
                color: _aiBlue,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  message.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _aiBlue,
                    fontSize: 10.8,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

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
                'Chat with your other AI',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900),
              ),
              SizedBox(height: 2),
              Text(
                'Ask for stock changes, then paste its JSON.',
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                    : const Tooltip(
                        message: 'Run command',
                        child: Icon(
                          Icons.arrow_upward_rounded,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _AiQuickActions extends StatelessWidget {
  const _AiQuickActions({required this.busy, required this.onTap});

  final bool busy;
  final ValueChanged<AiHubQuickAction> onTap;

  Future<void> _showMore(BuildContext context) async {
    if (busy) return;
    final action = await showModalBottomSheet<AiHubQuickAction>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, 2, 8, 8),
                  child: Text(
                    'More pharmacy actions',
                    style: TextStyle(
                      color: ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.inventory_2_outlined, color: red),
                title: const Text('Removed stock'),
                subtitle: const Text('Review removed medicines'),
                onTap: () => Navigator.pop(
                  sheetContext,
                  AiHubQuickAction.removed,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: red),
                title: const Text('Delete medicine'),
                subtitle: const Text('Choose the exact medicine first'),
                onTap: () => Navigator.pop(
                  sheetContext,
                  AiHubQuickAction.delete,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.edit_rounded, color: _aiPurple),
                title: const Text('Modify medicine'),
                subtitle: const Text('Open exact-row edit flow'),
                onTap: () => Navigator.pop(
                  sheetContext,
                  AiHubQuickAction.modify,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (action != null) onTap(action);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 5, 12, 7),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Row(
        children: [
          _AiQuickActionChip(
            label: 'Add',
            icon: Icons.add_rounded,
            color: green,
            onTap: busy ? null : () => onTap(AiHubQuickAction.add),
          ),
          const SizedBox(width: 8),
          _AiQuickActionChip(
            label: 'Sold',
            icon: Icons.shopping_cart_checkout_rounded,
            color: amber,
            onTap: busy ? null : () => onTap(AiHubQuickAction.sold),
          ),
          const SizedBox(width: 8),
          _AiQuickActionChip(
            label: 'Stock',
            icon: Icons.bar_chart_rounded,
            color: primary,
            onTap: busy ? null : () => onTap(AiHubQuickAction.stockSummary),
          ),
          const SizedBox(width: 8),
          _AiQuickActionChip(
            label: 'More',
            icon: Icons.more_horiz_rounded,
            color: _aiPurple,
            onTap: busy ? null : () => _showMore(context),
          ),
        ],
      ),
    ),
  );
}

class _AiQuickActionChip extends StatelessWidget {
  const _AiQuickActionChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 140),
      opacity: onTap == null ? .45 : 1,
      child: Material(
        color: dark ? const Color(0xFF1B2130) : Colors.white.withAlpha(238),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withAlpha(dark ? 72 : 42)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    color: ink,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
  final local = LocalAiService.instance;
  late bool localBrainEnabled;
  bool busy = false;
  bool apiExpanded = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    localBrainEnabled = widget.initial.localBrainEnabled;
  }

  Future<void> _setLocalBrain(bool value) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      if (value) {
        await local.initialize();
        final id = local.activeId;
        if (id == null) {
          throw StateError('Download or choose a Local AI model first.');
        }
        if (!local.isModelReady(id)) await local.activate(id);
      } else {
        await local.suspend();
      }
      await widget.service.setLocalBrainEnabled(value);
      if (mounted) setState(() => localBrainEnabled = value);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _brainRouteCard(BuildContext context) => AnimatedBuilder(
    animation: local,
    builder: (context, _) => Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: _aiPurple.withAlpha(localBrainEnabled ? 20 : 10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _aiPurple.withAlpha(55)),
      ),
      child: Row(
        children: [
          const Icon(Icons.psychology_alt_rounded, color: _aiPurple, size: 28),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Activate Aaris Brain',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 2),
                Text(
                  localBrainEnabled
                      ? widget.initial.key.isNotEmpty
                            ? 'ON · local model is active; your saved API stays connected independently.'
                            : 'ON · typed messages use ${local.activeLabel.isEmpty ? 'the selected local model' : local.activeLabel}.'
                      : widget.initial.key.isNotEmpty
                      ? 'OFF · typed messages use the saved API.'
                      : local.hasSelection
                      ? 'OFF · turn on to chat with the selected local model.'
                      : 'Download a local model below, or add an API key.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: localBrainEnabled,
            onChanged: busy || (!localBrainEnabled && !local.hasSelection)
                ? null
                : _setLocalBrain,
          ),
        ],
      ),
    ),
  );

  String get _providerLabel => widget.initial.providerLabel;

  Widget _apiFields(BuildContext context) => CloudAiConnectionPanel(
    initial: widget.initial,
    service: widget.service,
    localBrainEnabled: localBrainEnabled,
    blocked: busy,
    onSavingChanged: (value) {
      if (mounted) setState(() => busy = value);
    },
    onSaved: (config) {
      if (mounted) Navigator.pop(context, config);
    },
  );

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final scheme = Theme.of(context).colorScheme;
    final configured = widget.initial.key.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .92,
        ),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
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
              const SizedBox(height: 4),
              const Text(
                'Choose how Aaris uses AI.',
                style: TextStyle(color: muted, fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              const LocalModelsPanel(),
              const SizedBox(height: 10),
              _brainRouteCard(context),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error,
                    style: const TextStyle(color: red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 14),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: busy
                      ? null
                      : () => Navigator.pop(
                          context,
                          _AiConnectionsSheet.externalAction,
                        ),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: _aiPurple.withAlpha(14),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _aiPurple.withAlpha(60)),
                    ),
                    child: const Row(
                      children: [
                        _ExternalAiIcon(),
                        SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Connect with Other AI',
                                style: TextStyle(
                                  color: _aiPurple,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Share TXT · chat · review requested changes',
                                style: TextStyle(color: muted, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: _aiPurple,
                          size: 26,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: scheme.outlineVariant.withAlpha(90),
                  ),
                ),
                child: Column(
                  children: [
                    InkWell(
                      onTap: busy
                          ? null
                          : () => setState(() => apiExpanded = !apiExpanded),
                      borderRadius: BorderRadius.circular(20),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: primary.withAlpha(16),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.key_rounded,
                                color: primary,
                              ),
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Use AI inside the app',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    configured
                                        ? '$_providerLabel · Saved'
                                        : 'API key · Not configured',
                                    style: const TextStyle(
                                      color: muted,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (configured)
                              const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                                size: 22,
                              ),
                            const SizedBox(width: 6),
                            Icon(
                              apiExpanded
                                  ? Icons.expand_less_rounded
                                  : Icons.chevron_right_rounded,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (apiExpanded) _apiFields(context),
                  ],
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

bool _requiresExplicitLifecycleSelection(String operation) =>
    const {'remove', 'mark_sold', 'restore'}.contains(operation);

String _operationLabel(String operation) =>
    {
      'add': 'Add new stock',
      'update': 'Edit existing stock',
      'remove': 'Remove from inventory',
      'mark_sold': 'Mark out of stock · reorder',
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
      'supplierId': 'Supplier link',
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
