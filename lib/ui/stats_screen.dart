import 'package:flutter/material.dart';

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
              final labelHeight = maxTextHeight((metric) => metric.label, labelStyle);
              final detailHeight = maxTextHeight((metric) => metric.detail, detailStyle);
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
                  for (final metric in cards)
                    _SnapshotCard(metric: metric),
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
  });

  final String label;
  final String value;
  final String detail;
  final IconData icon;
}

class _SnapshotCard extends StatelessWidget {
  const _SnapshotCard({required this.metric});

  final _SnapshotMetric metric;

  @override
  Widget build(BuildContext context) => GlassPanel(
    radius: 22,
    elevation: 1,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DepthIcon(
            metric.icon,
            color: primary,
            background: primarySoft,
            size: 40,
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
            style: const TextStyle(
              fontSize: 11,
              height: 1.35,
              color: muted,
            ),
          ),
        ],
      ),
    ),
  );
}
