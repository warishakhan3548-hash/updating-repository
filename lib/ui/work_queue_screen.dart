import 'package:flutter/material.dart';

import '../domain/work_queue.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';

class WorkQueueScreen extends StatelessWidget {
  const WorkQueueScreen({super.key, required this.controller});

  final PharmacyController controller;

  PharmacyWorkQueue _queue() => PharmacyWorkQueue.build(
    medicines: controller.records,
    sales: controller.sales,
    settings: controller.settings,
    today: controller.today,
  );

  void _openTask(BuildContext context, PharmacistTask task) {
    final id = task.recordId;
    if (id == null) return;
    final record = controller.snapshot.records[id];
    if (record == null || record.archived) {
      showError(context, StateError('This stock entry is no longer available.'));
      return;
    }
    openEditor(context, controller, record: record);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Today’s work')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final queue = _queue();
        return ListView(
          key: const PageStorageKey('pharmacist-work-queue'),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
          children: [
            const ScreenIntro(
              title: 'Pharmacist priorities',
              message:
                  'Safety first, then stock availability and missing facts. Everything here is calculated locally from your saved inventory.',
              icon: Icons.fact_check_outlined,
            ),
            if (queue.isClear)
              const Surface(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DepthIcon(
                      Icons.verified_rounded,
                      color: green,
                      background: successSoft,
                      size: 44,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'No priority work right now',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Expiry, stock and core inventory facts have no current action waiting.',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _SummaryChip(
                    icon: Icons.warning_amber_rounded,
                    label: '${queue.criticalCount} critical',
                    color: red,
                    background: errorSoft,
                  ),
                  _SummaryChip(
                    icon: Icons.priority_high_rounded,
                    label: '${queue.highCount} high',
                    color: amber,
                    background: warningSoft,
                  ),
                  _SummaryChip(
                    icon: Icons.inventory_2_outlined,
                    label: '${queue.stockCount} stock',
                    color: primary,
                    background: primarySoft,
                  ),
                  _SummaryChip(
                    icon: Icons.edit_note_rounded,
                    label: '${queue.dataQualityCount} details',
                    color: primaryDeep,
                    background: primarySoft,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const SectionHeading('Do these first'),
              for (final task in queue.tasks) ...[
                _TaskCard(task: task, onTap: () => _openTask(context, task)),
                const SizedBox(height: 12),
              ],
            ],
            const SizedBox(height: 6),
            const Surface(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: primary, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This queue never changes stock automatically. Opening a task takes you to the exact saved stock entry; normal validation and review rules still control every write.',
                      style: TextStyle(color: muted, fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.background,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: .18)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 17),
        const SizedBox(width: 7),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.onTap});

  final PharmacistTask task;
  final VoidCallback onTap;

  Color get color => switch (task.priority) {
    PharmacistTaskPriority.critical => red,
    PharmacistTaskPriority.high => amber,
    PharmacistTaskPriority.routine => primary,
  };

  Color get background => switch (task.priority) {
    PharmacistTaskPriority.critical => errorSoft,
    PharmacistTaskPriority.high => warningSoft,
    PharmacistTaskPriority.routine => primarySoft,
  };

  IconData get icon => switch (task.kind) {
    PharmacistTaskKind.expired => Icons.event_busy_rounded,
    PharmacistTaskKind.shortExpiry => Icons.timelapse_rounded,
    PharmacistTaskKind.monthExpiry => Icons.calendar_month_rounded,
    PharmacistTaskKind.soldOut => Icons.remove_shopping_cart_outlined,
    PharmacistTaskKind.zeroQuantity => Icons.inventory_2_outlined,
    PharmacistTaskKind.reorder => Icons.add_shopping_cart_rounded,
    PharmacistTaskKind.missingExpiry => Icons.event_note_outlined,
    PharmacistTaskKind.missingQuantity => Icons.numbers_rounded,
    PharmacistTaskKind.missingLocation => Icons.location_on_outlined,
  };

  String get priorityLabel => switch (task.priority) {
    PharmacistTaskPriority.critical => 'Critical',
    PharmacistTaskPriority.high => 'High priority',
    PharmacistTaskPriority.routine => 'Review',
  };

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$priorityLabel. ${task.title}. ${task.message}',
    child: GlassPanel(
      radius: 22,
      elevation: .85,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DepthIcon(
                  icon,
                  color: color,
                  background: background,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        priorityLabel,
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        task.message,
                        style: const TextStyle(
                          color: muted,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, color: muted),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
