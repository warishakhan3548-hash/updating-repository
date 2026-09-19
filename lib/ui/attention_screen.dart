import 'package:flutter/material.dart';

import '../domain/attention.dart';
import '../domain/medicine.dart';
import '../domain/operations_plan.dart';
import '../domain/stock_guidance.dart';
import '../domain/tracking.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'demand_history_sheet.dart';
import 'editor_screen.dart';
import 'order_screen.dart';
import 'supplier_screen.dart';

class AttentionScreen extends StatefulWidget {
  const AttentionScreen({super.key, required this.controller});
  final PharmacyController controller;

  @override
  State<AttentionScreen> createState() => _AttentionScreenState();
}

class _AttentionScreenState extends State<AttentionScreen> {
  Object? _snapshot;
  DateTime? _day;
  List<StockGuidance> _tasks = const [];
  int _filter = 0;
  bool _opening = false;

  void _refresh() {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final today = controller.today;
    if (identical(snapshot, _snapshot) && today == _day) return;
    final tracking = controller.tracking(TrackingRange.lastDays(today, 30));
    final report = PharmacyAttentionReport.build(
      medicines: controller.records,
      settings: controller.settings,
      today: today,
      reorder: tracking.reorder,
      sales: controller.sales,
    );
    final plan = PharmacyOperationsPlan.build(
      items: report.items,
      medicines: controller.records,
    );
    final orders = {
      for (final order in tracking.reorder) order.productKey: order,
    };
    final dailyDemand = {
      for (final movement in tracking.movements.values)
        if (movement.demand != null) movement.key: movement.demand!,
    };
    final supplierTasks = supplierReturnGuidance(
      candidates: controller.supplierReturns,
    );
    final supplierDueIds = supplierTasks
        .expand((task) => task.stockIds)
        .toSet();
    final plannedTasks = <StockGuidance>[
      for (final step in plan.steps)
        StockGuidance.fromStep(
          step,
          records: snapshot.records,
          orders: orders,
          today: today,
          dailyDemand: dailyDemand,
        ),
    ];
    _tasks = [
      // A supplier return deadline is the more specific action. Do not show a
      // second generic short-expiry/expiry-waste card for the same exact stock.
      for (final task in plannedTasks)
        if (!(
          task.stockIds.any(supplierDueIds.contains) &&
          (task.step?.item.kind == AttentionKind.shortExpiry ||
              task.step?.item.kind == AttentionKind.expiryWastePressure)
        ))
          task,
      ...supplierTasks,
      ...stockMovementGuidance(
        tracking: tracking,
        records: snapshot.records,
        plan: plan,
        today: today,
      ),
    ];
    int priority(StockGuidance task) => task.critical
        ? 0
        : task.group == StockTaskGroup.urgent
        ? 1
        : task.group == StockTaskGroup.supplier
        ? 2
        : task.group == StockTaskGroup.order
        ? 3
        : task.group == StockTaskGroup.details
        ? 4
        : 5;
    // Display priority cannot bypass the planner's live prerequisites.
    final original = {for (var i = 0; i < _tasks.length; i++) _tasks[i].key: i};
    _tasks.sort((a, b) {
      final order = priority(a).compareTo(priority(b));
      return order != 0 ? order : original[a.key]!.compareTo(original[b.key]!);
    });
    _snapshot = snapshot;
    _day = today;
  }

  Future<void> _open(StockGuidance selected) async {
    if (_opening) return;
    _opening = true;
    try {
      // Revalidate after inventory updates; reject repeated navigation taps.
      _refresh();
      final task = _tasks.where((task) => task.key == selected.key).firstOrNull;
      if (task == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('सूची बदल गई है। नया काम चुनें।')),
          );
        }
        return;
      }
      if (task.group == StockTaskGroup.supplier) {
        final supplierId = task.supplierId;
        if (supplierId == null) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => SupplierScreen(controller: widget.controller),
            ),
          );
        } else {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => SupplierDetailScreen(
                controller: widget.controller,
                supplierId: supplierId,
              ),
            ),
          );
        }
        return;
      }
      final step = task.step;
      if (step == null && task.demand != null) {
        await _showHistory(task);
        return;
      }
      final target = step == null
          ? null
          : step.blocked
          ? step.prerequisites.first
          : step.item;
      if (target?.isReorder == true) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => OrderScreen(
              controller: widget.controller,
              range: TrackingRange.lastDays(widget.controller.today, 30),
              focusProductKey: target!.productKey,
            ),
          ),
        );
        return;
      }
      final ids = target?.stockIds ?? task.stockIds;
      final records = ids
          .map((id) => widget.controller.snapshot.records[id])
          .whereType<Medicine>()
          .where((record) => !record.archived)
          .toList(growable: false);
      if (records.isEmpty) return;
      var id = records.first.id;
      if (records.length > 1) {
        final chosen = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (sheetContext) => FractionallySizedBox(
            heightFactor: .72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          target == null
                              ? 'स्टॉक चुनें'
                              : stockActionLabel(target.kind),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'बंद करें',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: records.length,
                    itemBuilder: (_, index) {
                      final record = records[index];
                      return ListTile(
                        title: Text(record.title),
                        subtitle: Text(
                          [
                            if (record.address.isNotEmpty) record.address,
                            if (record.expiry != null)
                              'Expiry ${dateText(record.expiry!)}',
                            if (record.quantity != null)
                              '${record.quantity} यूनिट',
                          ].join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.pop(sheetContext, record.id),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
        if (chosen == null || !mounted) return;
        id = chosen;
      }
      final live = widget.controller.snapshot.records[id];
      if (!mounted || live == null || live.archived) return;
      await openEditor(context, widget.controller, record: live);
    } finally {
      _opening = false;
    }
  }

  Future<void> _showHistory(StockGuidance task) async {
    final key =
        task.step?.item.productKey ??
        widget.controller.snapshot.records[task.stockIds.firstOrNull]?.identity;
    if (key == null) return;
    await showDemandHistory(
      context,
      widget.controller,
      productKey: key,
      title: task.title,
    );
  }

  Future<void> _history(StockGuidance task) async {
    if (_opening) return;
    _opening = true;
    try {
      await _showHistory(task);
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('आज के काम')),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          _refresh();
          final visible = _filter == 0
              ? _tasks
              : _tasks
                    .where((task) => task.group.index == _filter - 1)
                    .toList();
          final indices = {
            for (var i = 0; i < visible.length; i++) visible[i].key: i + 1,
          };
          return ListView.builder(
            key: PageStorageKey('stock-tasks-$_filter'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: visible.length + (visible.isEmpty ? 2 : 1),
            findChildIndexCallback: (key) =>
                key is ValueKey<String> ? indices[key.value] : null,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tasks.isEmpty
                            ? 'अभी सब ठीक है'
                            : '${_tasks.length} छोटे काम · दवा पर टैप करें',
                        style: const TextStyle(color: muted, fontSize: 13),
                      ),
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final (i, label) in const [
                              'सभी',
                              'Expiry',
                              'मँगाएँ',
                              'Supplier',
                              'जानकारी',
                              'बिक्री',
                            ].indexed)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(label),
                                  selected: _filter == i,
                                  onSelected: (_) {
                                    if (_filter != i)
                                      setState(() => _filter = i);
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_filter == 3) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.push<void>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SupplierScreen(
                                  controller: widget.controller,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.local_shipping_outlined),
                            label: const Text('Supplier details'),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }
              if (visible.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Column(
                    children: [
                      Icon(
                        Icons.check_circle_outline_rounded,
                        color: green,
                        size: 36,
                      ),
                      SizedBox(height: 12),
                      Text('यहाँ अभी कोई काम नहीं है'),
                    ],
                  ),
                );
              }
              final task = visible[index - 1];
              return _AttentionCard(
                key: ValueKey(task.key),
                task: task,
                onTap: () => _open(task),
                onHistory: task.demand != null && task.step != null
                    ? () => _history(task)
                    : null,
              );
            },
          );
        },
      ),
    ),
  );
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({
    super.key,
    required this.task,
    required this.onTap,
    this.onHistory,
  });
  final StockGuidance task;
  final VoidCallback onTap;
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    final color = task.critical
        ? red
        : task.blocked
        ? amber
        : primary;
    final icon = task.critical
        ? Icons.event_busy_rounded
        : task.blocked
        ? Icons.fact_check_outlined
        : switch (task.group) {
            StockTaskGroup.urgent => Icons.timer_outlined,
            StockTaskGroup.order => Icons.add_shopping_cart_rounded,
            StockTaskGroup.supplier => Icons.assignment_return_outlined,
            StockTaskGroup.details => Icons.edit_note_rounded,
            StockTaskGroup.movement => Icons.insights_outlined,
          };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: .12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.action,
                      style: TextStyle(
                        color: color,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      task.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      task.reason,
                      style: const TextStyle(
                        color: muted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                    if (onHistory != null)
                      TextButton.icon(
                        onPressed: onHistory,
                        icon: const Icon(Icons.bar_chart_rounded, size: 18),
                        label: const Text('दिनवार बिक्री'),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, color: color, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
