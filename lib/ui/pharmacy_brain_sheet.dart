import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/pharmacy_brain.dart';
import '../state/pharmacy_brain_controller.dart';
import '../state/pharmacy_controller.dart';
import 'ai_screen.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'scanner_screen.dart';
import 'search_screen.dart';
import 'voice_sheet.dart';

Future<void> showPharmacyBrain(
  BuildContext context, {
  required PharmacyController controller,
  required ValueChanged<int> onSelectTab,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => PharmacyBrainSheet(
    controller: controller,
    onSelectTab: onSelectTab,
  ),
);

class PharmacyBrainSheet extends StatefulWidget {
  const PharmacyBrainSheet({
    super.key,
    required this.controller,
    required this.onSelectTab,
  });

  final PharmacyController controller;
  final ValueChanged<int> onSelectTab;

  @override
  State<PharmacyBrainSheet> createState() => _PharmacyBrainSheetState();
}

class _PharmacyBrainSheetState extends State<PharmacyBrainSheet> {
  late final PharmacyBrainController _brain = PharmacyBrainController(
    widget.controller,
  );
  final _input = TextEditingController();
  late PharmacyBrainPulse _pulse;
  PharmacyBrainOutcome? _outcome;
  ScanResult? _lastScan;
  bool _busy = false, _voiceOpening = false;
  String _status = '', _error = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _pulse = _brain.pulse();
  }

  @override
  void dispose() {
    ++_generation;
    _input.dispose();
    super.dispose();
  }

  Future<void> _run([String? command]) async {
    if (_busy) return;
    final raw = (command ?? _input.text).trim();
    if (raw.isEmpty) return;
    final generation = ++_generation;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _status = '';
      _error = '';
      _outcome = null;
      _lastScan = null;
    });
    try {
      final outcome = await _brain.interpret(raw);
      if (!mounted || generation != _generation) return;
      setState(() {
        _outcome = outcome;
        _pulse = _brain.pulse();
      });
      await _route(outcome);
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = _cleanError(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _route(PharmacyBrainOutcome outcome) async {
    switch (outcome.command.intent) {
      case PharmacyBrainIntent.addMedicine:
        await _closeAndPush(EditorScreen(controller: widget.controller));
        return;
      case PharmacyBrainIntent.scanMedicine:
        await _scan();
        return;
      case PharmacyBrainIntent.openDatabase:
        _selectTab(1);
        return;
      case PharmacyBrainIntent.openActivity:
        _selectTab(3);
        return;
      case PharmacyBrainIntent.openProfile:
        _selectTab(4);
        return;
      case PharmacyBrainIntent.openHome:
        _selectTab(0);
        return;
      case PharmacyBrainIntent.openAi:
        await _openAi();
        return;
      case PharmacyBrainIntent.openExpired:
        await _openScope(SearchScope.expired);
        return;
      case PharmacyBrainIntent.openShortExpiry:
        await _openScope(SearchScope.shortExpiry);
        return;
      case PharmacyBrainIntent.openMonthExpiry:
        await _openScope(SearchScope.monthExpiry);
        return;
      case PharmacyBrainIntent.openSold:
        await _openScope(SearchScope.sold);
        return;
      case PharmacyBrainIntent.searchMedicine || PharmacyBrainIntent.editMedicine:
        final exact = outcome.exact;
        if (exact != null) await _openMedicine(exact.record);
        return;
      case PharmacyBrainIntent.removeMedicine ||
          PharmacyBrainIntent.inventoryHealth ||
          PharmacyBrainIntent.blockedBulkRemove ||
          PharmacyBrainIntent.unknown:
        return;
    }
  }

  String _cleanError(Object error) => error.toString().replaceFirst(
    RegExp(r'^(FormatException|Bad state|StateError):\s*'),
    '',
  );

  void _selectTab(int index) {
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onSelectTab(index);
  }

  Future<void> _closeAndPush(Widget page) async {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    await navigator.push<void>(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _openAi() => _closeAndPush(
    Scaffold(
      appBar: AppBar(title: const Text('AI Controller')),
      body: AiScreen(controller: widget.controller),
    ),
  );

  Future<void> _openScope(SearchScope scope) => _closeAndPush(
    SearchScreen(controller: widget.controller, scope: scope),
  );

  Future<void> _openMedicine(Medicine medicine) => _closeAndPush(
    EditorScreen(controller: widget.controller, record: medicine),
  );

  Future<void> _voice() async {
    if (_voiceOpening || _busy) return;
    setState(() => _voiceOpening = true);
    try {
      final words = await voiceSearch(
        context,
        title: 'Aaris Brain',
        actionLabel: 'Use command',
      );
      if (!mounted || words == null || words.trim().isEmpty) return;
      _input.text = words.trim();
      await _run(words);
    } finally {
      if (mounted) setState(() => _voiceOpening = false);
    }
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<ScanResult>(
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (!mounted || result == null) return;
    final query = result.barcode.trim().isNotEmpty
        ? result.barcode.trim()
        : result.text.trim();
    setState(() {
      _lastScan = result;
      _input.text = query;
      _status = '';
      _error = '';
    });
    if (query.isEmpty) {
      setState(
        () => _status =
            'No searchable barcode/text was captured. Review the pack before adding it manually.',
      );
      return;
    }

    final generation = ++_generation;
    setState(() => _busy = true);
    try {
      final outcome = await _brain.interpret('find $query');
      if (!mounted || generation != _generation) return;
      setState(() {
        _outcome = outcome;
        _pulse = _brain.pulse();
      });
      final exact = outcome.exact;
      if (exact != null) await _openMedicine(exact.record);
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = _cleanError(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _addFromScan() async {
    final scan = _lastScan;
    if (scan == null) return;
    await _closeAndPush(
      EditorScreen(
        controller: widget.controller,
        barcode: scan.barcode,
        ocrText: scan.text,
      ),
    );
  }

  Future<void> _reviewRemoval(
    Medicine medicine,
    int expectedRevision,
  ) async {
    if (_busy) return;
    if (widget.controller.snapshot.revision != expectedRevision) {
      setState(
        () => _error =
            'Inventory changed after this medicine was matched. Run the command again.',
      );
      return;
    }

    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Remove ${medicine.title}?'),
        children: [
          for (final reason in const [
            'Sold / stock finished',
            'Expired',
            'Damaged',
            'Returned',
            'Correction',
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, reason),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
              child: Text(reason),
            ),
        ],
      ),
    );
    if (!mounted || reason == null) return;

    final sold = reason.startsWith('Sold');
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(sold ? 'Mark this stock sold?' : 'Confirm removal'),
            content: Text(
              sold
                  ? 'This marks only the resolved stock entry SOLD and keeps its history. It is not recorded as a customer sale.'
                  : 'Only the resolved stock entry leaves active inventory. History is preserved and can be restored.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(sold ? 'Mark sold' : 'Remove stock'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted || !confirmed) return;

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (widget.controller.snapshot.revision != expectedRevision) {
        throw StateError('Inventory changed. Run the command again before saving.');
      }
      if (sold) {
        await widget.controller.markSold(medicine.id);
      } else {
        await widget.controller.archive(
          medicine.id,
          reason,
          expectedRevision: expectedRevision,
        );
      }
      if (!mounted) return;
      setState(() {
        _outcome = null;
        _pulse = _brain.pulse();
        _status = sold
            ? '${medicine.title} is marked SOLD. Reorder views are updated.'
            : '${medicine.title} was removed safely. History is preserved${widget.controller.canUndo ? ' and Undo is available' : ''}.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pulsePanel() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: primary.withValues(alpha: .055),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: primary.withValues(alpha: .12)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Live pharmacy pulse',
          style: TextStyle(color: ink, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            _pill('Expired', _pulse.expired, danger: _pulse.expired > 0),
            _pill('Short expiry', _pulse.shortExpiry),
            _pill('Month', _pulse.monthExpiry),
            _pill('Sold', _pulse.sold),
            _pill('EXP unknown', _pulse.unknownExpiry),
          ],
        ),
      ],
    ),
  );

  Widget _pill(String label, int value, {bool danger = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: (danger ? red : primary).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      '$label · $value',
      style: TextStyle(
        color: danger ? red : primary,
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _message(String text, {bool warning = false}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: (warning ? amber : primary).withValues(alpha: .07),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: (warning ? amber : primary).withValues(alpha: .17),
      ),
    ),
    child: Text(text, style: const TextStyle(fontSize: 12.2, height: 1.4)),
  );

  Widget _candidateCard(
    PharmacyBrainCandidate candidate,
    PharmacyBrainOutcome outcome,
  ) {
    final medicine = candidate.record;
    final remove = outcome.command.intent == PharmacyBrainIntent.removeMedicine;
    final details = [
      candidate.hit.reason,
      if (medicine.expiry != null)
        'EXP ${medicine.expiryMonthOnly ? dateText(medicine.expiry!).substring(0, 7) : dateText(medicine.expiry!)}',
      if (medicine.batchNumber.isNotEmpty) 'Batch ${medicine.batchNumber}',
      if (medicine.address.isNotEmpty) medicine.address,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: _busy
            ? null
            : () => remove
                  ? _reviewRemoval(medicine, outcome.baseRevision)
                  : _openMedicine(medicine),
        leading: Icon(
          remove ? Icons.delete_outline_rounded : Icons.medication_outlined,
          color: remove ? red : primary,
        ),
        title: Text(
          medicine.title,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(details),
        trailing: Text(
          candidate.hit.confidence,
          style: const TextStyle(color: muted, fontSize: 10.5),
        ),
      ),
    );
  }

  Widget _outcomePanel() {
    final outcome = _outcome;
    if (outcome == null) return const SizedBox.shrink();
    final pulse = outcome.pulse;
    if (pulse != null) {
      return _message(
        '${outcome.message}\nExpired ${pulse.expired} · Short expiry ${pulse.shortExpiry} · Month expiry ${pulse.monthExpiry} · Zero quantity ${pulse.zeroQuantity} · EXP unknown ${pulse.unknownExpiry}',
      );
    }
    if (outcome.command.intent == PharmacyBrainIntent.blockedBulkRemove) {
      return _message(outcome.message, warning: true);
    }
    if (outcome.command.intent == PharmacyBrainIntent.unknown) {
      return Column(
        children: [
          _message(outcome.message),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _openAi,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Open full reviewed AI'),
            ),
          ),
        ],
      );
    }
    if (outcome.command.needsMedicine && outcome.candidates.isEmpty) {
      return Column(
        children: [
          _message(outcome.message, warning: true),
          if (_lastScan != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _addFromScan,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add from this scan'),
              ),
            ),
          ],
        ],
      );
    }
    if (outcome.command.intent == PharmacyBrainIntent.removeMedicine &&
        outcome.exact != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _message(
            'Exact stock target resolved. Nothing changes until you confirm the reason.',
            warning: true,
          ),
          const SizedBox(height: 8),
          _candidateCard(outcome.exact!, outcome),
        ],
      );
    }
    if (outcome.match == PharmacyBrainMatch.ambiguous) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _message(outcome.message, warning: outcome.command.destructive),
          const SizedBox(height: 8),
          for (final candidate in outcome.candidates)
            _candidateCard(candidate, outcome),
        ],
      );
    }
    return outcome.message.isEmpty
        ? const SizedBox.shrink()
        : _message(outcome.message);
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return FractionallySizedBox(
      heightFactor: .90,
      child: Material(
        color: const Color(0xFFF8FAFF),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 14 + keyboard),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF397BFF), Color(0xFF7857D8)],
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 11),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aaris Brain',
                          style: TextStyle(
                            color: ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          'Fast local commands · reviewed stock actions',
                          style: TextStyle(color: muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    _pulsePanel(),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _input,
                      enabled: !_busy,
                      maxLength: 500,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => unawaited(_run()),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: '“Dolo 650 delete kar do”',
                        prefixIcon: const Icon(Icons.bolt_rounded, color: primary),
                        suffixIcon: IconButton(
                          tooltip: 'Speak command',
                          onPressed: _voiceOpening || _busy ? null : _voice,
                          icon: _voiceOpening
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.mic_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _run,
                        icon: _busy
                            ? const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.arrow_forward_rounded),
                        label: Text(_busy ? 'Understanding…' : 'Do it safely'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final quick in const [
                          'आज क्या जरूरी है',
                          'Expired medicines',
                          'Scan medicine',
                          'Open database',
                        ])
                          ActionChip(
                            label: Text(quick),
                            onPressed: _busy
                                ? null
                                : () {
                                    _input.text = quick;
                                    unawaited(_run(quick));
                                  },
                          ),
                      ],
                    ),
                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _message(_status),
                    ],
                    if (_error.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _message(_error, warning: true),
                    ],
                    if (_outcome != null) ...[
                      const SizedBox(height: 12),
                      _outcomePanel(),
                    ],
                    const SizedBox(height: 18),
                    const Text(
                      'Safety: similar batches are never guessed. “Delete” means reviewed soft removal/history, never silent permanent deletion. Complex requests stay behind the full AI review flow.',
                      style: TextStyle(color: muted, fontSize: 11, height: 1.45),
                    ),
                    const SizedBox(height: 18),
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
