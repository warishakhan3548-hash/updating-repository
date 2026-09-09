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
  PharmacyBrainOutcome? _outcome;
  ScanResult? _lastScan;
  late PharmacyBrainPulse _pulse;
  bool _busy = false, _voiceOpening = false;
  String _error = '', _status = '';
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
      _error = '';
      _status = '';
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
        setState(
          () => _error = e.toString().replaceFirst(
            RegExp(r'^(FormatException|Bad state):\s*'),
            '',
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _route(PharmacyBrainOutcome outcome) async {
    switch (outcome.command.intent) {
      case PharmacyBrainIntent.addMedicine:
        await _closeAndPush(
          EditorScreen(controller: widget.controller),
        );
      case PharmacyBrainIntent.scanMedicine:
        await _scan();
      case PharmacyBrainIntent.openDatabase:
        _selectTab(1);
      case PharmacyBrainIntent.openActivity:
        _selectTab(3);
      case PharmacyBrainIntent.openProfile:
        _selectTab(4);
      case PharmacyBrainIntent.openHome:
        _selectTab(0);
      case PharmacyBrainIntent.openAi:
        await _closeAndPush(AiScreen(controller: widget.controller));
      case PharmacyBrainIntent.openExpired:
        await _openScope(SearchScope.expired);
      case PharmacyBrainIntent.openShortExpiry:
        await _openScope(SearchScope.shortExpiry);
      case PharmacyBrainIntent.openMonthExpiry:
        await _openScope(SearchScope.monthExpiry);
      case PharmacyBrainIntent.openSold:
        await _openScope(SearchScope.sold);
      case PharmacyBrainIntent.searchMedicine || PharmacyBrainIntent.editMedicine:
        final exact = outcome.exact;
        if (exact != null) await _openMedicine(exact.record);
      case PharmacyBrainIntent.removeMedicine:
        // Removal is intentionally held on this review surface. Even an exact
        // voice/text match cannot mutate stock without the pharmacist choosing
        // a reason and confirming the resolved batch.
        break;
      case PharmacyBrainIntent.inventoryHealth ||
          PharmacyBrainIntent.blockedBulkRemove ||
          PharmacyBrainIntent.unknown:
        break;
    }
  }

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
      final result = await voiceSearch(
        context,
        title: 'Aaris Brain',
        actionLabel: 'Use command',
      );
      if (!mounted || result == null || result.trim().isEmpty) return;
      _input.text = result.trim();
      await _run(result);
    } finally {
      if (mounted) setState(() => _voiceOpening = false);
    }
  }

  Future<void> _scan() async {
    if (!mounted) return;
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
      _error = '';
      _status = '';
    });
    if (query.isEmpty) {
      setState(
        () => _status =
            'The scan returned no searchable text. You can still add the medicine and review the pack manually.',
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
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _addFromLastScan() async {
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
            'Inventory changed after this medicine was matched. Run the command again before removing stock.',
      );
      return;
    }
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
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
              onPressed: () => Navigator.pop(ctx, reason),
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
          builder: (ctx) => AlertDialog(
            title: Text(sold ? 'Mark this stock sold?' : 'Confirm removal'),
            content: Text(
              sold
                  ? 'This marks the entire resolved stock entry SOLD and keeps its history. It is not recorded as a customer sale.'
                  : 'Only this resolved stock entry will leave active inventory. It stays in removed history and can be restored or undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
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
      if (sold) {
        if (widget.controller.snapshot.revision != expectedRevision) {
          throw StateError(
            'Inventory changed. Run the command again before marking this stock sold.',
          );
        }
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
      if (mounted) {
        setState(
          () => _error = e.toString().replaceFirst(
            RegExp(r'^(FormatException|Bad state):\s*'),
            '',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pulseCard() {
    final p = _pulse;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: .055),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: primary.withValues(alpha: .12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.monitor_heart_outlined, color: primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Live pharmacy pulse',
                style: TextStyle(fontWeight: FontWeight.w800, color: ink),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricPill(label: 'Expired', value: p.expired, urgent: p.expired > 0),
              _MetricPill(
                label: 'Short expiry',
                value: p.shortExpiry,
                urgent: p.shortExpiry > 0,
              ),
              _MetricPill(label: 'Month', value: p.monthExpiry),
              _MetricPill(label: 'Sold', value: p.sold),
              _MetricPill(label: 'EXP unknown', value: p.unknownExpiry),
            ],
          ),
        ],
      ),
    );
  }

  Widget _outcomeCard() {
    final outcome = _outcome;
    if (outcome == null) return const SizedBox.shrink();
    final command = outcome.command;
    final pulse = outcome.pulse;
    if (pulse != null) {
      return _BrainMessage(
        icon: Icons.priority_high_rounded,
        text:
            '${outcome.message}\nExpired ${pulse.expired} · Short expiry ${pulse.shortExpiry} · Month expiry ${pulse.monthExpiry} · Sold ${pulse.sold} · Zero quantity ${pulse.zeroQuantity} · EXP unknown ${pulse.unknownExpiry}',
      );
    }
    if (command.intent == PharmacyBrainIntent.blockedBulkRemove) {
      return _BrainMessage(
        icon: Icons.shield_outlined,
        text: outcome.message,
        warning: true,
      );
    }
    if (command.intent == PharmacyBrainIntent.unknown) {
      return Column(
        children: [
          _BrainMessage(icon: Icons.auto_awesome_rounded, text: outcome.message),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _closeAndPush(AiScreen(controller: widget.controller)),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Open full reviewed AI'),
            ),
          ),
        ],
      );
    }
    if (command.needsMedicine && outcome.candidates.isEmpty) {
      return Column(
        children: [
          _BrainMessage(
            icon: Icons.search_off_rounded,
            text: outcome.message,
            warning: true,
          ),
          if (_lastScan != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _addFromLastScan,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add from this scan'),
              ),
            ),
          ],
        ],
      );
    }
    if (command.intent == PharmacyBrainIntent.removeMedicine &&
        outcome.exact != null) {
      final medicine = outcome.exact!.record;
      return _MedicineDecisionCard(
        medicine: medicine,
        confidence: outcome.exact!.hit.confidence,
        message: 'Exact stock target resolved. Nothing changes until you confirm.',
        actionLabel: 'Review removal',
        destructive: true,
        onTap: () => _reviewRemoval(medicine, outcome.baseRevision),
      );
    }
    if (outcome.match == PharmacyBrainMatch.ambiguous) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BrainMessage(
            icon: Icons.rule_rounded,
            text: outcome.message,
            warning: command.destructive,
          ),
          const SizedBox(height: 10),
          for (final candidate in outcome.candidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _MedicineDecisionCard(
                medicine: candidate.record,
                confidence: candidate.hit.confidence,
                message: candidate.hit.reason,
                actionLabel: command.intent == PharmacyBrainIntent.removeMedicine
                    ? 'Choose & review'
                    : 'Open medicine',
                destructive: command.intent == PharmacyBrainIntent.removeMedicine,
                onTap: () => command.intent == PharmacyBrainIntent.removeMedicine
                    ? _reviewRemoval(candidate.record, outcome.baseRevision)
                    : _openMedicine(candidate.record),
              ),
            ),
        ],
      );
    }
    if (outcome.message.isNotEmpty) {
      return _BrainMessage(icon: Icons.check_circle_outline_rounded, text: outcome.message);
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return FractionallySizedBox(
      heightFactor: .90,
      child: Material(
        color: const Color(0xFFF8FAFF),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, 10, 18, 16 + bottom),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: muted.withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF397BFF), Color(0xFF7857D8)],
                      ),
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
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
                        SizedBox(height: 2),
                        Text(
                          'Local command router · inventory-safe actions',
                          style: TextStyle(color: muted, fontSize: 11.5),
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
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _pulseCard(),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _input,
                        enabled: !_busy,
                        maxLength: 500,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => unawaited(_run()),
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: 'e.g. “Dolo 650 delete kar do”',
                          prefixIcon: const Icon(Icons.bolt_rounded, color: primary),
                          suffixIcon: IconButton(
                            tooltip: 'Speak command',
                            onPressed: _voiceOpening || _busy ? null : _voice,
                            icon: _voiceOpening
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.mic_rounded),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _run,
                          icon: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.arrow_forward_rounded),
                          label: Text(_busy ? 'Understanding…' : 'Do it safely'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          for (final command in const [
                            'आज क्या जरूरी है',
                            'Expired medicines',
                            'Scan medicine',
                            'Open database',
                          ])
                            ActionChip(
                              label: Text(command),
                              onPressed: _busy
                                  ? null
                                  : () {
                                      _input.text = command;
                                      unawaited(_run(command));
                                    },
                            ),
                        ],
                      ),
                      if (_status.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _BrainMessage(
                          icon: Icons.check_circle_outline_rounded,
                          text: _status,
                        ),
                      ],
                      if (_error.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _BrainMessage(
                          icon: Icons.error_outline_rounded,
                          text: _error,
                          warning: true,
                        ),
                      ],
                      if (_outcome != null) ...[
                        const SizedBox(height: 14),
                        _outcomeCard(),
                      ],
                      const SizedBox(height: 18),
                      const Text(
                        'Brain rules',
                        style: TextStyle(color: ink, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Fast commands resolve against your real medicine database. Similar batches are never guessed. Remove means safe archive/history, not permanent deletion. Complex requests stay behind the full AI review flow.',
                        style: TextStyle(color: muted, fontSize: 11.5, height: 1.45),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.label,
    required this.value,
    this.urgent = false,
  });

  final String label;
  final int value;
  final bool urgent;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: (urgent ? red : primary).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      '$label · $value',
      style: TextStyle(
        color: urgent ? red : primary,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _BrainMessage extends StatelessWidget {
  const _BrainMessage({
    required this.icon,
    required this.text,
    this.warning = false,
  });

  final IconData icon;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: (warning ? amber : primary).withValues(alpha: .07),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: (warning ? amber : primary).withValues(alpha: .18),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: warning ? amber : primary, size: 20),
        const SizedBox(width: 9),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.4)),
        ),
      ],
    ),
  );
}

class _MedicineDecisionCard extends StatelessWidget {
  const _MedicineDecisionCard({
    required this.medicine,
    required this.confidence,
    required this.message,
    required this.actionLabel,
    required this.destructive,
    required this.onTap,
  });

  final Medicine medicine;
  final String confidence, message, actionLabel;
  final bool destructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final expiry = medicine.expiry == null
        ? 'EXP unknown'
        : 'EXP ${medicine.expiryMonthOnly ? dateText(medicine.expiry!).substring(0, 7) : dateText(medicine.expiry!)}';
    final details = [
      expiry,
      if (medicine.batchNumber.isNotEmpty) 'Batch ${medicine.batchNumber}',
      if (medicine.address.isNotEmpty) medicine.address,
    ].join(' · ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(
          color: (destructive ? red : primary).withValues(alpha: .14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  medicine.title,
                  style: const TextStyle(color: ink, fontWeight: FontWeight.w850),
                ),
              ),
              Text(
                confidence,
                style: const TextStyle(color: muted, fontSize: 10.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(details, style: const TextStyle(color: muted, fontSize: 11.5)),
          const SizedBox(height: 4),
          Text(message, style: const TextStyle(color: muted, fontSize: 11)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: destructive
                ? FilledButton.icon(
                    onPressed: onTap,
                    style: FilledButton.styleFrom(backgroundColor: red),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(actionLabel),
                  )
                : OutlinedButton.icon(
                    onPressed: onTap,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(actionLabel),
                  ),
          ),
        ],
      ),
    );
  }
}
