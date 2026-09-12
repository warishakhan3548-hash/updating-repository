import 'package:flutter/material.dart';

import '../domain/attention.dart';
import '../domain/medicine.dart';
import '../domain/operations_plan.dart';
import '../domain/tracking.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'order_screen.dart';

class AttentionScreen extends StatelessWidget {
  const AttentionScreen({super.key, required this.controller});

  final PharmacyController controller;

  PharmacyAttentionReport _report() {
    final range = TrackingRange.lastDays(controller.today, 30);
    return PharmacyAttentionReport.build(
      medicines: controller.records,
      settings: controller.settings,
      today: controller.today,
      reorder: controller.tracking(range).reorder,
      sales: controller.sales,
    );
  }

  Future<void> _openItem(BuildContext context, AttentionItem item) async {
    if (item.isReorder) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => OrderScreen(
            controller: controller,
            range: TrackingRange.lastDays(controller.today, 30),
          ),
        ),
      );
      return;
    }

    final records = item.stockIds
        .map((id) => controller.snapshot.records[id])
        .whereType<Medicine>()
        .where((medicine) => !medicine.archived)
        .toList(growable: false);
    if (records.length == 1) {
      await openEditor(context, controller, record: records.first);
      return;
    }
    if (records.isEmpty || !context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .78,
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
                        item.title,
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  item.detail,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                  itemCount: records.length,
                  itemBuilder: (_, index) {
                    final record = records[index];
                    return MedicineCard(
                      record: record,
                      settings: controller.settings,
                      today: controller.today,
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        await Future<void>.delayed(Duration.zero);
                        if (context.mounted) {
                          await openEditor(context, controller, record: record);
                        }
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

  Future<void> _openStep(BuildContext context, OperationsPlanStep step) async {
    // Downstream FEFO/reorder work is never opened ahead of a known prerequisite.
    // The user is taken to the first blocking fact instead, and the AnimatedBuilder
    // recalculates the plan from the authoritative controller after every edit.
    final target = step.prerequisites.isEmpty
        ? step.item
        : step.prerequisites.first;
    await _openItem(context, target);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Needs attention')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final report = _report();
        if (report.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified_rounded, color: green, size: 44),
                  SizedBox(height: 14),
                  Text(
                    'No operational issue needs attention right now.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Aaris checks expiry, FEFO waste pressure, stock consistency, batch fact conflicts, barcode identity, sale-history chronology, audit quality, missing automation facts, physical stock findability and deterministic reorder signals from local data.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, height: 1.4),
                  ),
                ],
              ),
            ),
          );
        }

        final plan = PharmacyOperationsPlan.build(
          items: report.items,
          medicines: controller.records,
        );
        final next = plan.nextStep;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
          children: [
            Surface(
              color: primarySoft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.route_rounded, color: primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Aaris operating plan',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${report.items.length} operational item${report.items.length == 1 ? '' : 's'} · ${plan.readyCount} ready now · ${plan.blockedCount} waiting on verified facts',
                    style: const TextStyle(
                      color: muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${report.critical} critical · ${report.high} high · ${report.medium} medium',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  if (next != null) ...[
                    const SizedBox(height: 14),
                    Material(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () async => _openStep(context, next),
                        child: Padding(
                          padding: const EdgeInsets.all(13),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'RECOMMENDED NEXT',
                                      style: TextStyle(
                                        color: primary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: .8,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      next.item.title,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      next.actionLabel,
                                      style: const TextStyle(
                                        color: muted,
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    const Text(
                                      'Tap to open this task',
                                      style: TextStyle(
                                        color: primary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Padding(
                                padding: EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.arrow_forward_rounded,
                                  color: primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  const Text(
                    'The plan is deterministic and local. It sequences prerequisite verification and physical findability before dependent FEFO work, but never diagnoses, invents medicine facts or changes inventory by itself.',
                    style: TextStyle(color: muted, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            for (final step in plan.steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _AttentionCard(
                  step: step,
                  onTap: () => _openStep(context, step),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.step, required this.onTap});

  final OperationsPlanStep step;
  final VoidCallback onTap;

  AttentionItem get item => step.item;

  Color get _color => switch (item.severity) {
    AttentionSeverity.critical => red,
    AttentionSeverity.high => amber,
    AttentionSeverity.medium => primary,
    AttentionSeverity.low => muted,
  };

  IconData get _icon => switch (item.kind) {
    AttentionKind.expiredStock => Icons.event_busy_rounded,
    AttentionKind.shortExpiry => Icons.timer_outlined,
    AttentionKind.expiryWastePressure => Icons.trending_down_rounded,
    AttentionKind.zeroQuantityMismatch => Icons.inventory_2_outlined,
    AttentionKind.missingStockLocation => Icons.location_searching_rounded,
    AttentionKind.barcodeConflict => Icons.qr_code_2_rounded,
    AttentionKind.conflictingLotFacts => Icons.rule_folder_outlined,
    AttentionKind.staleSoldMetadata => Icons.history_toggle_off_rounded,
    AttentionKind.soldAuditGap => Icons.receipt_long_outlined,
    AttentionKind.futureSaleHistory => Icons.schedule_rounded,
    AttentionKind.saleLifecycleConflict => Icons.history_edu_rounded,
    AttentionKind.urgentReorder => Icons.priority_high_rounded,
    AttentionKind.reorderReview => Icons.shopping_cart_checkout_rounded,
    AttentionKind.unknownExpiry => Icons.event_note_rounded,
    AttentionKind.unknownQuantity => Icons.numbers_rounded,
    AttentionKind.futureManufactureDate => Icons.event_repeat_rounded,
    AttentionKind.possibleDuplicateBatch => Icons.content_copy_rounded,
  };

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _color.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_icon, color: _color, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.laneLabel.toUpperCase(),
                    style: TextStyle(
                      color: _color,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .7,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.detail,
                    style: const TextStyle(
                      color: muted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    step.blocked
                        ? 'Fix ${step.prerequisites.length} prerequisite ${step.prerequisites.length == 1 ? 'item' : 'items'} first. Tap to open the first blocker.'
                        : step.actionLabel,
                    style: TextStyle(
                      color: step.blocked ? amber : _color,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              step.blocked
                  ? Icons.lock_clock_rounded
                  : Icons.chevron_right_rounded,
              color: _color,
            ),
          ],
        ),
      ),
    ),
  );
}
