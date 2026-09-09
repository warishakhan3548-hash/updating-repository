import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/app_brain.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/search.dart';
import '../state/pharmacy_controller.dart';
import 'ai_screen.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'search_screen.dart';
import 'voice_sheet.dart';

class BrainScreen extends StatefulWidget {
  const BrainScreen({
    super.key,
    required this.controller,
    required this.onOpenSection,
  });

  final PharmacyController controller;
  final ValueChanged<AppSection> onOpenSection;

  @override
  State<BrainScreen> createState() => _BrainScreenState();
}

class _BrainScreenState extends State<BrainScreen> {
  final _command = TextEditingController();
  bool _busy = false, _voiceOpening = false;
  String? _lastTargetId;
  String _reply =
      'Instant App Brain is ready. It handles everyday pharmacy commands locally, remembers the last exact medicine you selected, and sends deeper reasoning to the reviewed AI Controller below.';

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  Future<void> _run([String? supplied]) async {
    if (_busy) return;
    final raw = (supplied ?? _command.text).trim();
    if (raw.isEmpty) return;
    final intent = parseAppBrainIntent(raw);
    setState(() {
      _busy = true;
      _reply = 'Understanding command…';
      if (supplied != null) _command.text = supplied;
    });
    try {
      await _execute(intent, raw);
    } catch (error) {
      if (mounted) {
        setState(
          () => _reply = error
              .toString()
              .replaceFirst(RegExp(r'^(FormatException|Bad state):\s*'), ''),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _execute(AppBrainIntent intent, String raw) async {
    switch (intent.action) {
      case AppBrainAction.navigate:
        final section = intent.section;
        if (section == null) {
          _unknown(raw);
          return;
        }
        widget.onOpenSection(section);
        if (mounted) setState(() => _reply = _sectionReply(section));
        return;
      case AppBrainAction.addMedicine:
        if (mounted) {
          widget.onOpenSection(AppSection.stock);
          setState(() => _reply = 'Opening a fresh medicine entry.');
          await openEditor(context, widget.controller);
        }
        return;
      case AppBrainAction.search:
        await _searchIntent(intent);
        return;
      case AppBrainAction.editMedicine:
      case AppBrainAction.removeMedicine:
      case AppBrainAction.markSold:
      case AppBrainAction.recordSale:
        await _medicineAction(intent);
        return;
      case AppBrainAction.undoLast:
        await _undo();
        return;
      case AppBrainAction.inventorySummary:
        _summary();
        return;
      case AppBrainAction.attentionBrief:
        _attentionBrief();
        return;
      case AppBrainAction.bulkRemoveBlocked:
        _bulkRemoveBlocked();
        return;
      case AppBrainAction.unknown:
        _unknown(raw);
        return;
    }
  }

  Future<void> _searchIntent(AppBrainIntent intent) async {
    final query = intent.query.trim();
    if (query.isEmpty) {
      if (!mounted) return;
      if (intent.scope == SearchScope.all) {
        widget.onOpenSection(AppSection.stock);
        setState(() => _reply = 'Medicine Database opened.');
        return;
      }
      setState(
        () => _reply = 'Opening ${scopeTitle(intent.scope, widget.controller.settings)}.',
      );
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => SearchScreen(
            controller: widget.controller,
            scope: intent.scope,
          ),
        ),
      );
      return;
    }
    final hits = await widget.controller.search(query, intent.scope);
    if (!mounted) return;
    final direct = _singleSafeTarget(
      hits.where((hit) => hit.score >= .90).take(8).toList(),
    );
    if (direct != null) {
      final record = widget.controller.snapshot.records[direct.id];
      if (record != null && !record.archived) _remember(record);
    }
    await _showMatches(
      hits,
      title: 'Matches for “$query”',
      emptyReply:
          'No confident local stock match for “$query”. I opened the Medicine Database so you can scan or search another spelling.',
    );
  }

  Future<void> _medicineAction(AppBrainIntent intent) async {
    final query = intent.query.trim();
    if (isAppBrainContextReference(query)) {
      final remembered = _rememberedTarget();
      if (remembered == null) {
        widget.onOpenSection(AppSection.stock);
        if (mounted) {
          setState(
            () => _reply =
                'I do not have a safe previous medicine target yet. Medicine Database opened so you can choose the exact stock entry first.',
          );
        }
        return;
      }
      await _openActionTarget(intent.action, remembered, fromContext: true);
      return;
    }

    if (query.isEmpty) {
      if (!mounted) return;
      widget.onOpenSection(AppSection.stock);
      setState(
        () => _reply =
            'Medicine name, batch, barcode or location is missing. Medicine Database opened so you can choose the exact stock entry safely.',
      );
      return;
    }

    final hits = await widget.controller.search(query, SearchScope.all);
    if (!mounted) return;
    final viable = hits.where((hit) => hit.score >= .90).take(8).toList();
    if (viable.isEmpty) {
      widget.onOpenSection(AppSection.stock);
      setState(
        () => _reply =
            'I could not safely identify “$query”. Medicine Database opened instead of guessing the wrong stock entry.',
      );
      return;
    }

    final direct = _singleSafeTarget(viable);
    if (direct != null) {
      final record = widget.controller.snapshot.records[direct.id];
      if (record != null && !record.archived) {
        await _openActionTarget(intent.action, record);
        return;
      }
    }

    await _showMatches(
      viable,
      title: _choiceTitle(intent.action, query),
      emptyReply: 'No safe match found. I will not guess a medicine or batch.',
      action: intent.action,
    );
  }

  Future<void> _openActionTarget(
    AppBrainAction action,
    Medicine record, {
    bool fromContext = false,
  }) async {
    _remember(record);
    widget.onOpenSection(AppSection.stock);
    if (!mounted) return;
    setState(
      () => _reply = fromContext
          ? 'Using your last exact selection: ${record.title}. ${_editorInstruction(action, record)}'
          : _editorInstruction(action, record),
    );
    // Put the Medicine Database behind the editor route so the user lands in
    // the correct inventory context instead of being stranded on the Brain tab.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await openEditor(context, widget.controller, record: record);
  }

  void _remember(Medicine record) {
    if (!record.archived) _lastTargetId = record.id;
  }

  Medicine? _rememberedTarget() {
    final id = _lastTargetId;
    if (id == null) return null;
    final record = widget.controller.snapshot.records[id];
    if (record == null || record.archived) {
      _lastTargetId = null;
      return null;
    }
    return record;
  }

  SearchHit? _singleSafeTarget(List<SearchHit> hits) {
    if (hits.isEmpty) return null;
    final first = hits.first;
    if (first.uncertain || first.score < .95) return null;
    if (hits.length == 1) return first;
    final second = hits[1];
    if (second.score >= .90 && (first.score - second.score).abs() < .08) {
      return null;
    }
    return first;
  }

  Future<void> _showMatches(
    List<SearchHit> hits, {
    required String title,
    required String emptyReply,
    AppBrainAction action = AppBrainAction.search,
  }) async {
    final records = <Medicine>[];
    final seen = <String>{};
    for (final hit in hits) {
      final record = widget.controller.snapshot.records[hit.id];
      if (record != null && !record.archived && seen.add(record.id)) {
        records.add(record);
      }
      if (records.length >= 12) break;
    }
    if (records.isEmpty) {
      widget.onOpenSection(AppSection.stock);
      if (mounted) setState(() => _reply = emptyReply);
      return;
    }
    if (records.length == 1) _remember(records.first);
    setState(
      () => _reply = records.length == 1
          ? '1 stock entry found. I will remember it for follow-up commands like “isko edit karo”.'
          : '${records.length} possible stock entries found. Choose the exact batch; Aaris will not guess.',
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .82,
        child: Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              if (action != AppBrainAction.search)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Choose the exact medicine/batch. Aaris will remember this choice; existing safety confirmation remains mandatory.',
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                  itemCount: records.length,
                  itemBuilder: (_, index) {
                    final record = records[index];
                    return MedicineCard(
                      record: record,
                      settings: widget.controller.settings,
                      today: widget.controller.today,
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        if (!mounted) return;
                        _remember(record);
                        if (action == AppBrainAction.search) {
                          widget.onOpenSection(AppSection.stock);
                          setState(
                            () => _reply =
                                '${record.title} selected. I will remember this exact stock entry for your next command.',
                          );
                          await Future<void>.delayed(Duration.zero);
                          if (mounted) {
                            await openEditor(
                              context,
                              widget.controller,
                              record: record,
                            );
                          }
                          return;
                        }
                        await _openActionTarget(action, record);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _undo() async {
    if (!widget.controller.canUndo) {
      setState(() => _reply = 'There is no current change available to undo.');
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Undo last inventory change?'),
            content: const Text(
              'Aaris will restore the immediately previous inventory state through the existing audited undo transaction.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Undo'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Undo cancelled. Nothing changed.');
      return;
    }
    await widget.controller.undo();
    if (mounted) {
      setState(() => _reply = 'Last reviewed inventory change was undone.');
    }
  }

  void _summary() {
    final stats = widget.controller.stats;
    final active = widget.controller.records.where((m) => !m.archived).length;
    final expired = widget.controller.list(SearchScope.expired).length;
    final sold = widget.controller.list(SearchScope.sold).length;
    setState(
      () => _reply =
          'Inventory now: $active active stock entries · ${stats.uniqueMedicines} unique medicines · ${stats.knownUnits} known units · $expired expired · $sold sold/reorder entries · ${stats.unknownQuantity} entries with unknown quantity.',
    );
  }

  void _attentionBrief() {
    final active = widget.controller.records.where((m) => !m.archived).toList();
    final expired = widget.controller.list(SearchScope.expired).length;
    final shortExpiry = widget.controller.list(SearchScope.shortExpiry).length;
    final monthExpiry = widget.controller.list(SearchScope.monthExpiry).length;
    final sold = widget.controller.list(SearchScope.sold).length;
    final unknownExpiry = active
        .where((m) => !m.sold && m.expiry == null)
        .length;
    final unknownQuantity = active
        .where((m) => !m.sold && m.quantity == null)
        .length;
    final missingSalt = active.where((m) => m.salt.trim().isEmpty).length;

    if (expired == 0 &&
        shortExpiry == 0 &&
        sold == 0 &&
        unknownExpiry == 0 &&
        unknownQuantity == 0 &&
        missingSalt == 0) {
      setState(
        () => _reply =
            'Attention brief: no urgent expiry, reorder, quantity or missing-data issue is visible right now. $monthExpiry medicine${monthExpiry == 1 ? '' : 's'} are inside your month-expiry window.',
      );
      return;
    }

    setState(
      () => _reply =
          'Attention brief · $expired expired · $shortExpiry short-expiry · $monthExpiry month-expiry · $sold sold/reorder · $unknownExpiry expiry unknown · $unknownQuantity quantity unknown · $missingSalt salt missing. Start with expired/short-expiry stock, then reorder and missing facts.',
    );
  }

  void _bulkRemoveBlocked() {
    widget.onOpenSection(AppSection.profile);
    setState(
      () => _reply =
          'Bulk removal is intentionally blocked from natural-language commands. Profile opened at the protected owner area; “Remove all inventory” still requires its dedicated multi-step confirmation so a voice/AI misunderstanding cannot wipe stock.',
    );
  }

  void _unknown(String raw) {
    setState(
      () => _reply =
          '“$raw” looks like a deeper reasoning request rather than a deterministic app command. Use the AI Controller composer directly below; its Local AI → Aaris Default AI → configured provider safety pipeline remains authoritative for complex reasoning and proposed inventory changes.',
    );
  }

  String _editorInstruction(AppBrainAction action, Medicine record) =>
      switch (action) {
        AppBrainAction.removeMedicine =>
          '${record.title} opened in Medicine Database. Use Remove; Aaris keeps reason + confirmation + removed history mandatory.',
        AppBrainAction.markSold =>
          '${record.title} opened in Medicine Database. Use Mark sold only if this entire stock entry is finished; confirmation remains required.',
        AppBrainAction.recordSale =>
          '${record.title} opened in Medicine Database. Use Record sale; FEFO and expiry validation remain active.',
        AppBrainAction.editMedicine =>
          '${record.title} opened in Medicine Database for review/edit.',
        _ => '${record.title} opened.',
      };

  String _choiceTitle(AppBrainAction action, String query) => switch (action) {
    AppBrainAction.removeMedicine => 'Choose stock to remove · $query',
    AppBrainAction.markSold => 'Choose stock to mark sold · $query',
    AppBrainAction.recordSale => 'Choose stock for sale · $query',
    AppBrainAction.editMedicine => 'Choose stock to edit · $query',
    _ => 'Choose medicine · $query',
  };

  String _sectionReply(AppSection section) => switch (section) {
    AppSection.home => 'Home opened.',
    AppSection.stock => 'Medicine Database opened.',
    AppSection.ai => 'AI Controller is already open.',
    AppSection.calculator => 'Calculator opened.',
    AppSection.profile => 'Profile opened.',
  };

  Future<void> _voice() async {
    if (_voiceOpening || _busy) return;
    setState(() => _voiceOpening = true);
    try {
      final words = await voiceSearch(
        context,
        offlineOnly: true,
        title: 'Speak an app command',
        actionLabel: 'Run command',
      );
      if (mounted && words != null && words.trim().isNotEmpty) {
        await _run(words.trim());
      }
    } finally {
      if (mounted) setState(() => _voiceOpening = false);
    }
  }

  Widget _brainBar(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        child: Surface(
          color: primarySoft,
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.psychology_alt_rounded, color: primary),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Aaris App Brain · instant offline commands',
                      style: TextStyle(fontWeight: FontWeight.w900, color: ink),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _command,
                      enabled: !_busy,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_run()),
                      decoration: const InputDecoration(
                        hintText:
                            'Dolo 650 delete karo · batch AB12 · aaj kya dekhna hai',
                        prefixIcon: Icon(Icons.bolt_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Speak command',
                    onPressed: _voiceOpening || _busy ? null : _voice,
                    icon: const Icon(Icons.mic_rounded),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    tooltip: 'Run command',
                    onPressed: _busy ? null : _run,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.arrow_forward_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                _reply,
                style: const TextStyle(color: muted, fontSize: 11.5, height: 1.35),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _QuickCommand('Needs attention', 'aaj kya dekhna hai'),
                    _QuickCommand('Expired', 'expired medicines dikhao'),
                    _QuickCommand('Sold', 'sold medicines dikhao'),
                    _QuickCommand('Stock summary', 'stock summary'),
                    _QuickCommand('Add medicine', 'add medicine'),
                    _QuickCommand('Undo', 'undo last'),
                  ]
                      .map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(right: 7),
                          child: ActionChip(
                            label: Text(item.label),
                            onPressed: _busy ? null : () => _run(item.command),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Column(
        children: [
          _brainBar(context),
          Expanded(child: AiScreen(controller: widget.controller)),
        ],
      );
}

class _QuickCommand {
  const _QuickCommand(this.label, this.command);
  final String label, command;
}
