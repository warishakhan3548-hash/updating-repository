import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/pharmacy_brain.dart';
import '../domain/tracking.dart';
import '../state/pharmacy_controller.dart';
import 'backup_screen.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'order_screen.dart';
import 'scanner_screen.dart';
import 'search_screen.dart';
import 'voice_sheet.dart';

Future<void> showPharmacyBrain(
  BuildContext context,
  PharmacyController controller, {
  VoidCallback? onOpenAi,
}) async {
  final destination = await showModalBottomSheet<_BrainDestination>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => _PharmacyBrainSheet(controller: controller),
  );
  if (!context.mounted || destination == null) return;

  switch (destination.kind) {
    case _BrainDestinationKind.add:
      await openEditor(context, controller);
      return;
    case _BrainDestinationKind.scan:
      await _scanAndResolve(context, controller);
      return;
    case _BrainDestinationKind.medicine:
      final medicine = destination.medicine;
      if (medicine != null) await openEditor(context, controller, record: medicine);
      return;
    case _BrainDestinationKind.scope:
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SearchScreen(
            controller: controller,
            scope: destination.scope ?? SearchScope.all,
            database: true,
          ),
        ),
      );
      return;
    case _BrainDestinationKind.backup:
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => BackupScreen(controller: controller)),
      );
      return;
    case _BrainDestinationKind.orders:
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => OrderScreen(
            controller: controller,
            range: TrackingRange.lastDays(controller.today, 30),
          ),
        ),
      );
      return;
    case _BrainDestinationKind.ai:
      onOpenAi?.call();
      return;
  }
}

Future<void> _scanAndResolve(
  BuildContext context,
  PharmacyController controller,
) async {
  final scan = await Navigator.of(context).push<ScanResult>(
    MaterialPageRoute(builder: (_) => const ScannerScreen()),
  );
  if (scan == null || !context.mounted) return;

  final query = scan.barcode.trim().isNotEmpty ? scan.barcode : scan.text;
  if (query.trim().isNotEmpty) {
    final hits = await controller.search(query, SearchScope.all);
    if (!context.mounted) return;
    final candidates = hits
        .take(8)
        .map((hit) => controller.snapshot.records[hit.id])
        .whereType<Medicine>()
        .where((medicine) => !medicine.archived)
        .toList();
    if (candidates.isNotEmpty) {
      final exactBarcode = scan.barcode.trim().isNotEmpty
          ? candidates
                .where(
                  (medicine) =>
                      medicine.barcode.trim() == scan.barcode.trim(),
                )
                .toList()
          : const <Medicine>[];
      final selected = exactBarcode.length == 1
          ? exactBarcode.single
          : await _pickMedicine(
              context,
              candidates,
              controller.today,
              title: 'Choose scanned medicine',
            );
      if (selected != null && context.mounted) {
        await openEditor(context, controller, record: selected);
        return;
      }
    }
  }

  if (context.mounted) {
    await openEditor(
      context,
      controller,
      barcode: scan.barcode,
      ocrText: scan.text,
    );
  }
}

Future<Medicine?> _pickMedicine(
  BuildContext context,
  List<Medicine> candidates,
  DateTime today, {
  String title = 'Choose the exact stock entry',
}) => showDialog<Medicine>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 520,
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: candidates.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, index) {
          final medicine = candidates[index];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              medicine.title,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(_stockCue(medicine, today)),
            onTap: () => Navigator.pop(dialogContext, medicine),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Cancel'),
      ),
    ],
  ),
);

String _stockCue(Medicine medicine, DateTime today) {
  final expiry = medicine.expiry == null
      ? 'EXP unknown'
      : statusOf(medicine, const WarningSettings(), today).label;
  return [
    expiry,
    if (medicine.batchNumber.isNotEmpty) 'Batch ${medicine.batchNumber}',
    if (medicine.address.isNotEmpty) medicine.address,
    if (medicine.quantity != null) 'Qty ${medicine.quantity}',
  ].join(' · ');
}

enum _BrainDestinationKind { add, scan, medicine, scope, backup, orders, ai }

class _BrainDestination {
  const _BrainDestination._(
    this.kind, {
    this.medicine,
    this.scope,
  });

  const _BrainDestination.add() : this._(_BrainDestinationKind.add);
  const _BrainDestination.scan() : this._(_BrainDestinationKind.scan);
  const _BrainDestination.backup() : this._(_BrainDestinationKind.backup);
  const _BrainDestination.orders() : this._(_BrainDestinationKind.orders);
  const _BrainDestination.ai() : this._(_BrainDestinationKind.ai);
  const _BrainDestination.medicine(Medicine medicine)
    : this._(_BrainDestinationKind.medicine, medicine: medicine);
  const _BrainDestination.scope(SearchScope scope)
    : this._(_BrainDestinationKind.scope, scope: scope);

  final _BrainDestinationKind kind;
  final Medicine? medicine;
  final SearchScope? scope;
}

class _PharmacyBrainSheet extends StatefulWidget {
  const _PharmacyBrainSheet({required this.controller});

  final PharmacyController controller;

  @override
  State<_PharmacyBrainSheet> createState() => _PharmacyBrainSheetState();
}

class _PharmacyBrainSheetState extends State<_PharmacyBrainSheet> {
  final _input = TextEditingController();
  bool _busy = false, _voiceOpening = false;
  String _message =
      'Tell Aaris what you want to do. Common stock commands run locally first, without waiting for an AI model.';
  PharmacyBrainRisk _messageRisk = PharmacyBrainRisk.readOnly;

  PharmacyController get controller => widget.controller;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _voice() async {
    if (_voiceOpening || _busy) return;
    setState(() => _voiceOpening = true);
    try {
      final text = await voiceSearch(context);
      if (text != null && mounted) {
        _input.text = text;
        await _run(text);
      }
    } finally {
      if (mounted) setState(() => _voiceOpening = false);
    }
  }

  Future<void> _run(String raw) async {
    if (_busy) return;
    final plan = PharmacyBrain.understand(raw);
    if (!plan.handled) {
      setState(() {
        _message = plan.message;
        _messageRisk = plan.risk;
      });
      return;
    }

    setState(() {
      _busy = true;
      _message = plan.message;
      _messageRisk = plan.risk;
    });
    try {
      switch (plan.intent) {
        case PharmacyBrainIntent.addMedicine:
          if (mounted) Navigator.pop(context, const _BrainDestination.add());
          return;
        case PharmacyBrainIntent.scanMedicine:
          if (mounted) Navigator.pop(context, const _BrainDestination.scan());
          return;
        case PharmacyBrainIntent.showExpired:
          if (mounted) {
            Navigator.pop(
              context,
              const _BrainDestination.scope(SearchScope.expired),
            );
          }
          return;
        case PharmacyBrainIntent.showShortExpiry:
          if (mounted) {
            Navigator.pop(
              context,
              const _BrainDestination.scope(SearchScope.shortExpiry),
            );
          }
          return;
        case PharmacyBrainIntent.showMonthExpiry:
          if (mounted) {
            Navigator.pop(
              context,
              const _BrainDestination.scope(SearchScope.monthExpiry),
            );
          }
          return;
        case PharmacyBrainIntent.showSold:
          if (mounted) {
            Navigator.pop(
              context,
              const _BrainDestination.scope(SearchScope.sold),
            );
          }
          return;
        case PharmacyBrainIntent.openBackup:
          if (mounted) Navigator.pop(context, const _BrainDestination.backup());
          return;
        case PharmacyBrainIntent.openOrders:
          if (mounted) Navigator.pop(context, const _BrainDestination.orders());
          return;
        case PharmacyBrainIntent.findMedicine:
        case PharmacyBrainIntent.editMedicine:
        case PharmacyBrainIntent.sellMedicine:
        case PharmacyBrainIntent.removeMedicine:
          await _medicineAction(plan);
          return;
        case PharmacyBrainIntent.none:
          return;
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error
              .toString()
              .replaceFirst(RegExp(r'^(FormatException|Bad state):\s*'), '');
          _messageRisk = PharmacyBrainRisk.destructive;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _medicineAction(PharmacyBrainPlan plan) async {
    if (plan.query.trim().isEmpty) {
      setState(() {
        _message =
            'Tell me the exact medicine name, strength, barcode, batch or location so I can target the correct stock entry.';
      });
      return;
    }

    final resolutionRevision = controller.snapshot.revision;
    final hits = await controller.search(plan.query, SearchScope.all);
    if (!mounted) return;
    final candidates = hits
        .where((hit) => hit.score >= .55)
        .take(8)
        .map((hit) => controller.snapshot.records[hit.id])
        .whereType<Medicine>()
        .where((medicine) => !medicine.archived)
        .toList();

    if (candidates.isEmpty) {
      setState(() {
        _message =
            'I could not find a reliable local match for “${plan.query}”. Try the barcode, strength, batch number or scanner.';
        _messageRisk = PharmacyBrainRisk.readOnly;
      });
      return;
    }

    final top = hits.first;
    final secondScore = hits.length > 1 ? hits[1].score : -1.0;
    final autoResolve = candidates.length == 1 ||
        (top.score >= .93 && top.score - secondScore >= .10);
    final medicine = autoResolve
        ? candidates.first
        : await _pickMedicine(context, candidates, controller.today);
    if (medicine == null || !mounted) return;

    if (plan.intent == PharmacyBrainIntent.removeMedicine) {
      await _removeMedicine(medicine, resolutionRevision);
      return;
    }

    if (plan.intent == PharmacyBrainIntent.sellMedicine) {
      setState(() {
        _message =
            '${medicine.title} found. Opening its stock details so the sale quantity and sold-out state stay explicitly reviewed.';
        _messageRisk = PharmacyBrainRisk.reviewRequired;
      });
    }
    if (mounted) {
      Navigator.pop(context, _BrainDestination.medicine(medicine));
    }
  }

  Future<void> _removeMedicine(Medicine medicine, int expectedRevision) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Remove ${medicine.name} — choose reason'),
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
    if (reason == null || !mounted) return;

    if (reason.startsWith('Sold')) {
      final confirmed = await _confirm(
        'Mark ${medicine.name} sold?',
        '${_stockCue(medicine, controller.today)}\n\nThis marks the whole stock entry out of stock and adds it to reorder. It does not invent a customer sale.',
        'Mark sold',
      );
      if (!confirmed || !mounted) return;
      if (expectedRevision != controller.snapshot.revision) {
        throw StateError(
          'Inventory changed while this action was open. Run the command again so Aaris can re-check the exact stock entry.',
        );
      }
      await controller.markSold(medicine.id);
      if (mounted) {
        setState(() {
          _message = '${medicine.title} is now marked sold and ready for reorder.';
          _messageRisk = PharmacyBrainRisk.readOnly;
        });
      }
      return;
    }

    final confirmed = await _confirm(
      'Remove ${medicine.name}?',
      '${_stockCue(medicine, controller.today)}\n\nReason: $reason\n\nThe entry will be archived, not permanently erased. History and restore remain available.',
      'Remove stock',
    );
    if (!confirmed || !mounted) return;
    await controller.archive(
      medicine.id,
      reason,
      expectedRevision: expectedRevision,
    );
    if (mounted) {
      setState(() {
        _message =
            '${medicine.title} was removed with reason “$reason”. The archived history is preserved.';
        _messageRisk = PharmacyBrainRisk.readOnly;
      });
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Color get _messageColor => switch (_messageRisk) {
    PharmacyBrainRisk.readOnly => primary,
    PharmacyBrainRisk.reviewRequired => amber,
    PharmacyBrainRisk.destructive => red,
  };

  @override
  Widget build(BuildContext context) {
    final expired = controller.list(SearchScope.expired).length;
    final shortExpiry = controller.list(SearchScope.shortExpiry).length;
    final sold = controller.list(SearchScope.sold).length;
    final missingExpiry = controller.records
        .where(
          (medicine) =>
              !medicine.archived && !medicine.sold && medicine.expiry == null,
        )
        .length;

    return Padding(
      padding: EdgeInsets.only(
        left: 14,
        right: 14,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 14,
      ),
      child: GlassPanel(
        tint: Colors.white,
        radius: 30,
        blurSigma: 18,
        elevation: 1.2,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const DepthIcon(Icons.auto_awesome_rounded, size: 44),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aaris Brain',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: ink,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Offline command layer · exact stock safety gates',
                          style: TextStyle(color: muted, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _IntelChip(
                    icon: Icons.warning_amber_rounded,
                    label: '$expired expired',
                    onTap: _busy ? null : () => _run('expired medicines'),
                  ),
                  _IntelChip(
                    icon: Icons.timelapse_rounded,
                    label: '$shortExpiry short expiry',
                    onTap: _busy ? null : () => _run('short expiry medicines'),
                  ),
                  _IntelChip(
                    icon: Icons.replay_circle_filled_outlined,
                    label: '$sold reorder',
                    onTap: _busy ? null : () => _run('sold medicines'),
                  ),
                  _IntelChip(
                    icon: Icons.help_outline_rounded,
                    label: '$missingExpiry EXP unknown',
                    onTap: _busy
                        ? null
                        : () {
                            setState(() {
                              _message = missingExpiry == 0
                                  ? 'Every active unsold stock entry currently has an expiry recorded.'
                                  : '$missingExpiry active stock ${missingExpiry == 1 ? 'entry has' : 'entries have'} no recorded expiry. Search or scan those packs before dispensing.';
                              _messageRisk = missingExpiry == 0
                                  ? PharmacyBrainRisk.readOnly
                                  : PharmacyBrainRisk.reviewRequired;
                            });
                          },
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Surface(
                color: _messageColor.withValues(alpha: .07),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _messageRisk == PharmacyBrainRisk.destructive
                          ? Icons.shield_outlined
                          : Icons.psychology_alt_outlined,
                      color: _messageColor,
                      size: 20,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        _message,
                        style: const TextStyle(fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _input,
                enabled: !_busy,
                autofocus: true,
                textInputAction: TextInputAction.send,
                onSubmitted: _run,
                decoration: InputDecoration(
                  hintText: 'e.g. Dolo 650 delete kar do',
                  prefixIcon: const Icon(Icons.auto_awesome_rounded),
                  suffixIcon: IconButton(
                    tooltip: 'Voice command',
                    onPressed: _voiceOpening || _busy ? null : _voice,
                    icon: _voiceOpening
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.mic_none_rounded),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _run(_input.text),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward_rounded),
                      label: const Text('Run command'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(
                            context,
                            const _BrainDestination.ai(),
                          ),
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    label: const Text('Full AI'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                    label: const Text('Scan'),
                    onPressed: _busy ? null : () => _run('scan'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add medicine'),
                    onPressed: _busy ? null : () => _run('add medicine'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: const Text('Reorder'),
                    onPressed: _busy ? null : () => _run('reorder'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.backup_outlined, size: 18),
                    label: const Text('Backup'),
                    onPressed: _busy ? null : () => _run('backup'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntelChip extends StatelessWidget {
  const _IntelChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: Icon(icon, size: 17),
    label: Text(label),
    onPressed: onTap,
  );
}
