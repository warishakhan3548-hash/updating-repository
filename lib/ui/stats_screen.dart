import 'package:flutter/material.dart';

import '../domain/sales_overview.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key, required this.controller});

  final PharmacyController controller;

  String _money(int paise) => '₹${(paise / 100).toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final inventory = controller.stats;
      final sales = SalesOverview(
        controller.sales,
        medicines: controller.records,
        events: controller.snapshot.events,
      );
      final ranked = sales.ranked;
      final top = ranked.isEmpty ? null : ranked.first;
      final topShare = top?.demandShare(sales.totalUnitsSold) ?? 0;
      final cards = [
        _SnapshotMetric(
          label: 'Medicines',
          value: '${inventory.uniqueMedicines}',
          detail: 'Unique name + strength + form',
          icon: Icons.medication_outlined,
        ),
        _SnapshotMetric(
          label: 'Stock units',
          value: '${inventory.knownUnits}',
          detail: '${inventory.unknownQuantity} unknown quantities',
          icon: Icons.widgets_outlined,
        ),
        _SnapshotMetric(
          label: 'Unique salts',
          value: '${inventory.uniqueSalts}',
          detail: '${inventory.missingSalt} entries without salt',
          icon: Icons.science_outlined,
        ),
        _SnapshotMetric(
          label: 'Sold entries',
          value: '${inventory.soldEntries}',
          detail: 'Manual out-of-stock confirmations',
          icon: Icons.check_circle_outline_rounded,
        ),
        _SnapshotMetric(
          label: 'Total amount',
          value: _money(inventory.totalEnteredAmountPaise),
          detail: 'Sum of amounts entered for medicines',
          icon: Icons.currency_rupee_rounded,
        ),
        _SnapshotMetric(
          label: 'Number of medicines',
          value: '${inventory.uniqueMedicineNames}',
          detail: 'Distinct medicine names, not stock units',
          icon: Icons.format_list_numbered_rounded,
        ),
        _SnapshotMetric(
          label: 'Sales Value',
          value: _money(sales.salesValuePaise),
          detail: sales.unknownValueSales == 0
              ? 'From recorded medicine sales'
              : '${sales.unknownValueSales} sales without a known value',
          icon: Icons.payments_outlined,
        ),
        _SnapshotMetric(
          label: 'Sold Medicine Tracker',
          value: top == null ? '—' : '${(topShare * 100).round()}%',
          detail: top == null
              ? 'No recorded sales yet'
              : '${top.name} · ${top.unitsSold} units sold',
          icon: Icons.bar_chart_rounded,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  _SoldMedicineTrackerScreen(controller: controller),
            ),
          ),
        ),
      ];

      return ListView(
        key: const PageStorageKey('pharmacy-snapshot-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 30),
        children: [
          Text(
            'Pharmacy snapshot',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final scaler = MediaQuery.textScalerOf(context);
              final columns =
                  constraints.maxWidth < 290 || scaler.scale(14) > 21
                  ? 1
                  : constraints.maxWidth > 700
                  ? 4
                  : 2;
              final spacing = 14.0;
              final cardWidth =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;

              double maxTextHeight(
                String Function(_SnapshotMetric metric) text,
                TextStyle style,
              ) {
                var maxHeight = 0.0;
                for (final metric in cards) {
                  final painter = TextPainter(
                    text: TextSpan(text: text(metric), style: style),
                    textDirection: Directionality.of(context),
                    textScaler: scaler,
                    maxLines: 3,
                  )..layout(maxWidth: cardWidth - 32);
                  if (painter.height > maxHeight) maxHeight = painter.height;
                  painter.dispose();
                }
                return maxHeight;
              }

              const labelStyle = TextStyle(
                fontSize: 14,
                height: 1.3,
                fontWeight: FontWeight.w800,
                color: ink,
              );
              const detailStyle = TextStyle(
                fontSize: 11,
                height: 1.35,
                color: muted,
              );
              final labelHeight = maxTextHeight(
                (metric) => metric.label,
                labelStyle,
              );
              final detailHeight = maxTextHeight(
                (metric) => metric.detail,
                detailStyle,
              );
              final cardHeight =
                  32 +
                  40 +
                  13 +
                  scaler.scale(36) * 1.2 +
                  8 +
                  labelHeight +
                  5 +
                  detailHeight;

              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: columns,
                mainAxisSpacing: spacing,
                crossAxisSpacing: spacing,
                childAspectRatio: cardWidth / cardHeight,
                children: [
                  for (final metric in cards) _SnapshotCard(metric: metric),
                ],
              );
            },
          ),
        ],
      );
    },
  );
}

class _SnapshotMetric {
  const _SnapshotMetric({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    this.onTap,
  });

  final String label;
  final String value;
  final String detail;
  final IconData icon;
  final VoidCallback? onTap;
}

class _SnapshotCard extends StatelessWidget {
  const _SnapshotCard({required this.metric});

  final _SnapshotMetric metric;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DepthIcon(
                metric.icon,
                color: primary,
                background: primarySoft,
                size: 40,
              ),
              if (metric.onTap != null) ...[
                const Spacer(),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: primary,
                  size: 22,
                ),
              ],
            ],
          ),
          const SizedBox(height: 13),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              metric.value,
              style: const TextStyle(
                color: ink,
                fontSize: 36,
                height: 1.2,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            metric.label,
            style: const TextStyle(
              fontSize: 14,
              height: 1.3,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            metric.detail,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, height: 1.35, color: muted),
          ),
        ],
      ),
    );

    return Semantics(
      button: metric.onTap != null,
      label: metric.onTap == null
          ? null
          : '${metric.label}. ${metric.detail}. Open full tracker.',
      child: GlassPanel(
        radius: 22,
        elevation: 1,
        child: metric.onTap == null
            ? content
            : Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: metric.onTap,
                  borderRadius: BorderRadius.circular(22),
                  child: content,
                ),
              ),
      ),
    );
  }
}

class _SoldMedicineTrackerScreen extends StatelessWidget {
  const _SoldMedicineTrackerScreen({required this.controller});

  final PharmacyController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sold Medicine Tracker')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final overview = SalesOverview(
          controller.sales,
          medicines: controller.records,
          events: controller.snapshot.events,
        );
        final ranked = overview.ranked;
        if (ranked.isEmpty) {
          return const EmptyState(
            title: 'No recorded sales yet',
            message: 'Record medicine sales to build the demand tracker.',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            GlassPanel(
              tint: primarySoft,
              accentColor: primary,
              radius: 22,
              elevation: .9,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const DepthIcon(
                    Icons.bar_chart_rounded,
                    color: primary,
                    background: Colors.white,
                    size: 44,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${overview.totalUnitsSold} units sold',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${ranked.length} medicines ranked by recorded demand',
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < ranked.length; i++) ...[
              _DemandRow(
                rank: i + 1,
                demand: ranked[i],
                totalUnitsSold: overview.totalUnitsSold,
              ),
              if (i != ranked.length - 1) const SizedBox(height: 12),
            ],
          ],
        );
      },
    ),
  );
}

class _DemandRow extends StatelessWidget {
  const _DemandRow({
    required this.rank,
    required this.demand,
    required this.totalUnitsSold,
  });

  final int rank;
  final SoldMedicineDemand demand;
  final int totalUnitsSold;

  @override
  Widget build(BuildContext context) {
    final share = demand.demandShare(totalUnitsSold);
    final percentage = share * 100;
    final percentText =
        percentage < 10 && percentage != percentage.roundToDouble()
        ? '${percentage.toStringAsFixed(1)}%'
        : '${percentage.round()}%';
    return GlassPanel(
      radius: 22,
      elevation: .85,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$rank',
                  style: const TextStyle(
                    color: primaryDeep,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  demand.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                percentText,
                style: const TextStyle(
                  color: primaryDeep,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: share,
              minHeight: 10,
              backgroundColor: primarySoft,
              color: primary,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            '${demand.unitsSold} units sold · ${demand.recordedSales} recorded ${demand.recordedSales == 1 ? 'sale' : 'sales'}',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
