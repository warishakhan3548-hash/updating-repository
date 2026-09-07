import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../domain/tracking.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'order_screen.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.controller});

  final PharmacyController controller;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late TrackingRange _range = TrackingRange.lastDays(
    widget.controller.today,
    30,
  );
  int? _preset = 30;

  Future<void> _customRange() async {
    final today = widget.controller.today;
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 10, today.month, today.day),
      lastDate: today,
      initialDateRange: DateTimeRange(start: _range.start, end: _range.end),
      helpText: 'Choose tracking period',
    );
    if (selected != null && mounted) {
      setState(() {
        _range = TrackingRange(start: selected.start, end: selected.end);
        _preset = null;
      });
    }
  }

  void _usePreset(int days) => setState(() {
    _preset = days;
    _range = TrackingRange.lastDays(widget.controller.today, days);
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final effectiveRange = _preset == null
          ? _range
          : TrackingRange.lastDays(widget.controller.today, _preset!);
      final inventory = widget.controller.stats;
      final tracking = widget.controller.tracking(effectiveRange);
      final recentSales =
          widget.controller.sales
              .where((sale) => effectiveRange.contains(sale.occurredAt))
              .toList()
            ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
      return ListView(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 30),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tracking',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Inventory, movement and reorder intelligence.',
                      style: TextStyle(color: muted, fontSize: 14),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: lime,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(Icons.insights_rounded, color: ink),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final days in [7, 30, 90]) ...[
                  ChoiceChip(
                    label: Text('$days days'),
                    selected: _preset == days,
                    onSelected: (_) => _usePreset(days),
                  ),
                  const SizedBox(width: 8),
                ],
                ActionChip(
                  avatar: const Icon(Icons.date_range_outlined, size: 18),
                  label: Text(
                    _preset == null
                        ? '${dateText(_range.start)} → ${dateText(_range.end)}'
                        : 'Custom',
                  ),
                  onPressed: _customRange,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Surface(
            color: ink,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ON-HAND INVENTORY VALUE',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.5,
                    color: Color(0xFFBDD0C4),
                  ),
                ),
                const SizedBox(height: 15),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    money(inventory.onHandValue),
                    style: const TextStyle(
                      fontSize: 38,
                      letterSpacing: -1,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${inventory.valuedEntries} valued · ${inventory.unvaluedEntries} missing quantity or price',
                  style: const TextStyle(
                    color: Color(0xFFC5D8CC),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SectionHeading('Pharmacy snapshot'),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth > 620
                  ? 4
                  : MediaQuery.textScalerOf(context).scale(14) > 22
                  ? 1
                  : 2;
              final cards = [
                _Metric(
                  'Medicines',
                  '${inventory.uniqueMedicines}',
                  'Unique name + strength + form',
                  Icons.medication_outlined,
                ),
                _Metric(
                  'Stock units',
                  '${inventory.knownUnits}',
                  '${inventory.unknownQuantity} unknown quantities',
                  Icons.widgets_outlined,
                ),
                _Metric(
                  'Unique salts',
                  '${inventory.uniqueSalts}',
                  '${inventory.missingSalt} entries without salt',
                  Icons.science_outlined,
                ),
                _Metric(
                  'Sold entries',
                  '${inventory.soldEntries}',
                  'Manual out-of-stock confirmations',
                  Icons.check_circle_outline_rounded,
                ),
              ];
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: cards
                    .map(
                      (metric) => SizedBox(
                        width:
                            (constraints.maxWidth - 12 * (columns - 1)) /
                            columns,
                        child: _MetricCard(metric: metric),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          SectionHeading(
            'Reorder intelligence',
            action: StatusPill(
              '${tracking.reorder.length} suggestions',
              color:
                  tracking.reorder.any(
                    (item) => item.priority == ReorderPriority.urgent,
                  )
                  ? red
                  : amber,
            ),
          ),
          if (tracking.reorder.isEmpty)
            const Surface(
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline_rounded, color: green),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No sold-out or low-stock medicine needs an order right now.',
                    ),
                  ),
                ],
              ),
            )
          else ...[
            for (final suggestion in tracking.reorder.take(4))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Surface(
                  padding: const EdgeInsets.all(17),
                  color: suggestion.priority == ReorderPriority.urgent
                      ? const Color(0xFFFFECE8)
                      : const Color(0xFFFFF4DC),
                  child: Row(
                    children: [
                      Icon(
                        suggestion.priority == ReorderPriority.urgent
                            ? Icons.priority_high_rounded
                            : Icons.trending_down_rounded,
                        color: suggestion.priority == ReorderPriority.urgent
                            ? red
                            : amber,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              suggestion.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${suggestion.reason} · suggested ${suggestion.suggestedQuantity}',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => OrderScreen(
                    controller: widget.controller,
                    range: effectiveRange,
                  ),
                ),
              ),
              icon: const Icon(Icons.shopping_cart_checkout_rounded),
              label: Text('Order Now · ${tracking.reorder.length} medicines'),
            ),
          ],
          const SectionHeading('Sales movement'),
          Row(
            children: [
              Expanded(
                child: _CompactMetric(
                  label: 'Units sold',
                  value: '${tracking.unitsSold}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CompactMetric(
                  label: 'Recorded sales',
                  value: '${tracking.recordedSales}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Surface(
            child: Row(
              children: [
                const Icon(Icons.currency_rupee_rounded, color: green),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        money(tracking.revenuePaise),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        '${tracking.unknownRevenueSales} sales excluded because amount was not entered',
                        style: const TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SectionHeading('Most sold & fast moving'),
          if (tracking.fastestMoving.isEmpty)
            const Surface(
              child: Text(
                'Record medicine sales to calculate demand and fast-moving stock.',
              ),
            )
          else
            for (final movement in tracking.fastestMoving.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Surface(
                  padding: const EdgeInsets.all(17),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF1E3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.trending_up_rounded,
                          color: green,
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              movement.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${movement.recordedSales} sale events · ${movement.unitsPerDay.toStringAsFixed(1)} units/day',
                              style: const TextStyle(
                                fontSize: 11,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${movement.unitsSold}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                ),
              ),
          const SectionHeading('Slow moving'),
          if (tracking.slowMoving.isEmpty)
            const Surface(
              child: Text(
                'No on-hand medicine moved less than one unit per week in this period.',
              ),
            )
          else
            for (final movement in tracking.slowMoving.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Surface(
                  padding: const EdgeInsets.all(17),
                  child: Row(
                    children: [
                      const Icon(Icons.hourglass_bottom_rounded, color: amber),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              movement.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${movement.unitsSold} units moved in ${effectiveRange.days} days${movement.currentQuantity == null ? ' · stock unknown' : ' · ${movement.currentQuantity} in stock'}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          const SectionHeading('Stock by medicine form'),
          if (inventory.byForm.isEmpty)
            const Surface(child: Text('Form counts appear as you add stock.')),
          for (final entry in inventory.byForm.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Surface(
                padding: const EdgeInsets.all(17),
                child: Row(
                  children: [
                    const Icon(Icons.medication_outlined, color: green),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.key,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${entry.value.records} stock entries · ${entry.value.unknownQuantity} unknown quantities',
                            style: const TextStyle(fontSize: 11, color: muted),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${entry.value.units}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
              ),
            ),
          const SectionHeading('Recent movement'),
          if (recentSales.isEmpty)
            const Surface(child: Text('No sales were recorded in this period.'))
          else
            for (final sale in recentSales.take(20))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Surface(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.point_of_sale_outlined, color: green),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sale.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${dateText(sale.occurredAt)} · ${sale.quantity} units',
                              style: const TextStyle(
                                fontSize: 11,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        sale.totalAmountPaise == null
                            ? '—'
                            : money(sale.totalAmountPaise!),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
          const SectionHeading('Value checks'),
          _ValueCheck(
            title: 'Expired stock value',
            value: money(inventory.expiredValue),
            detail: 'Included in on-hand value; review this stock separately.',
            color: red,
          ),
          const SizedBox(height: 12),
          _ValueCheck(
            title: 'Stock value when marked sold',
            value: money(widget.controller.snapshot.soldValue),
            detail:
                'Historical estimate, not sales revenue. ${widget.controller.snapshot.unknownSold} events had missing values.',
            color: amber,
          ),
        ],
      );
    },
  );
}

class _Metric {
  const _Metric(this.label, this.value, this.detail, this.icon);
  final String label;
  final String value;
  final String detail;
  final IconData icon;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric});
  final _Metric metric;

  @override
  Widget build(BuildContext context) => Surface(
    padding: const EdgeInsets.all(17),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(metric.icon, color: green),
        const SizedBox(height: 13),
        Text(metric.value, style: Theme.of(context).textTheme.headlineMedium),
        Text(metric.label, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(
          metric.detail,
          style: const TextStyle(fontSize: 10.5, color: muted),
        ),
      ],
    ),
  );
}

class _CompactMetric extends StatelessWidget {
  const _CompactMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Surface(
    padding: const EdgeInsets.all(17),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: Theme.of(context).textTheme.headlineMedium),
        Text(label, style: const TextStyle(color: muted, fontSize: 12)),
      ],
    ),
  );
}

class _ValueCheck extends StatelessWidget {
  const _ValueCheck({
    required this.title,
    required this.value,
    required this.detail,
    required this.color,
  });
  final String title;
  final String value;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) => Surface(
    color: color.withValues(alpha: .07),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 7),
        Text(value, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 6),
        Text(detail, style: const TextStyle(fontSize: 11, color: muted)),
      ],
    ),
  );
}
