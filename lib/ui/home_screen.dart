import 'package:flutter/material.dart';

import '../state/pharmacy_controller.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/date_input.dart';
import 'design.dart';
import 'search_screen.dart';
import 'editor_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.onDatabase,
  });
  final PharmacyController controller;
  final VoidCallback onDatabase;
  void _open(BuildContext context, SearchScope scope) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SearchScreen(controller: controller, scope: scope),
        ),
      );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final short = controller.list(SearchScope.shortExpiry);
      final month = controller.list(SearchScope.monthExpiry);
      final expired = controller.list(SearchScope.expired);
      final sold = controller.list(SearchScope.sold);
      final records = controller.list(SearchScope.all);
      final attention = [...expired, ...short, ...month].take(4).toList();
      final hour = controller.clock().hour;
      final greeting = hour < 12
          ? 'Good morning!'
          : hour < 17
          ? 'Good afternoon!'
          : 'Good evening!';
      return ListView(
        key: const PageStorageKey('home-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        children: [
          Row(
            children: [
              const DepthIcon(
                Icons.add_rounded,
                color: lime,
                background: ink,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Aaris Pharmacy',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Text(
                      'Your inventory, in order',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Expiry warning settings',
                onPressed: () => showWarningSettings(context, controller),
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(greeting, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 7),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              const Text(
                'Your stock. Clearly organised.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              Text(
                inputDateText(controller.today),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ],
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
              final tiles = [
                _OverviewTile(
                  title:
                      '${controller.settings.shortDays} ${controller.settings.shortDays == 1 ? 'Day' : 'Days'} Left',
                  caption: 'Short expiry',
                  count: short.length,
                  icon: Icons.timelapse_rounded,
                  color: green,
                  background: const Color(0xFFE5F6D7),
                  onTap: () => _open(context, SearchScope.shortExpiry),
                ),
                _OverviewTile(
                  title:
                      '${controller.settings.months} ${controller.settings.months == 1 ? 'Month' : 'Months'} Left',
                  caption: 'Month warning',
                  count: month.length,
                  icon: Icons.calendar_month_rounded,
                  color: const Color(0xFF146F62),
                  background: const Color(0xFFE0F3EB),
                  onTap: () => _open(context, SearchScope.monthExpiry),
                ),
                _OverviewTile(
                  title: 'Sold Medicines',
                  caption: 'Ready to reorder',
                  count: sold.length,
                  icon: Icons.check_circle_outline_rounded,
                  color: amber,
                  background: const Color(0xFFFFF0CD),
                  onTap: () => _open(context, SearchScope.sold),
                ),
                _OverviewTile(
                  title: 'Expired Medicines',
                  caption: 'Review your stock',
                  count: expired.length,
                  icon: Icons.event_busy_rounded,
                  color: red,
                  background: const Color(0xFFFCE5E1),
                  onTap: () => _open(context, SearchScope.expired),
                ),
              ];
              final cardWidth =
                  (constraints.maxWidth - 14 * (columns - 1)) / columns;
              double maxTextHeight(bool caption) {
                var maxHeight = 0.0;
                for (final tile in tiles) {
                  final painter = TextPainter(
                    text: TextSpan(
                      text: caption ? tile.caption : tile.title,
                      style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                        fontSize: caption ? 11 : 14,
                        height: 1.3,
                        fontWeight: caption
                            ? FontWeight.normal
                            : FontWeight.w800,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    textScaler: scaler,
                  )..layout(maxWidth: cardWidth - 32);
                  if (painter.height > maxHeight) maxHeight = painter.height;
                  painter.dispose();
                }
                return maxHeight;
              }

              // Use one measured height for all four cards, including large text.
              final height =
                  102 +
                  scaler.scale(36) * 1.2 +
                  maxTextHeight(false) +
                  maxTextHeight(true);
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: columns,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio:
                    ((constraints.maxWidth - 14 * (columns - 1)) / columns) /
                    height,
                children: tiles,
              );
            },
          ),
          const SizedBox(height: 22),
          _ScanBanner(onTap: () => _open(context, SearchScope.all)),
          const SizedBox(height: 18),
          Surface(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const DepthIcon(Icons.inventory_2_outlined, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${controller.stats.uniqueMedicines} medicines in your care',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Text(
                        'Saved on this device',
                        style: TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Add medicine',
                  onPressed: () => openEditor(context, controller),
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
              ],
            ),
          ),
          SectionHeading(
            'Attention first',
            action: TextButton(
              onPressed: onDatabase,
              child: const Text('View all →'),
            ),
          ),
          if (records.isEmpty)
            EmptyState(
              title: 'Start with your first medicine',
              message:
                  'Add its name now. Fill in expiry, location and price when you have them.',
              action: FilledButton.icon(
                onPressed: () => openEditor(context, controller),
                icon: const Icon(Icons.add),
                label: const Text('Add medicine'),
              ),
            )
          else if (attention.isEmpty)
            const Surface(
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline, color: green),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('No stock needs an expiry review today.'),
                  ),
                ],
              ),
            )
          else
            ...attention.map(
              (m) => MedicineCard(
                record: m,
                settings: controller.settings,
                today: controller.today,
                onTap: () => openEditor(context, controller, record: m),
              ),
            ),
        ],
      );
    },
  );
}

class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    required this.title,
    required this.caption,
    required this.count,
    required this.icon,
    required this.color,
    required this.background,
    required this.onTap,
  });
  final String title, caption;
  final int count;
  final IconData icon;
  final Color color, background;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$title, $count medicines. $caption',
    child: Container(
      decoration: depthDecoration(background),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Stack(
              children: [
                Positioned(
                  right: -12,
                  bottom: -14,
                  child: ExcludeSemantics(
                    child: Transform.rotate(
                      angle: -.25,
                      child: Icon(
                        icon,
                        size: 86,
                        color: color.withValues(alpha: .08),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          DepthIcon(
                            icon,
                            color: color,
                            background: Color.alphaBlend(
                              color.withValues(alpha: .12),
                              background,
                            ),
                            size: 42,
                          ),
                          const Spacer(),
                          Icon(
                            Icons.north_east_rounded,
                            color: color,
                            size: 20,
                          ),
                        ],
                      ),
                      const SizedBox(height: 13),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '$count',

                          style: TextStyle(
                            color: color,
                            fontSize: 36,
                            height: 1.2,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.3,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        caption,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.3,
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
      ),
    ),
  );
}

class _ScanBanner extends StatelessWidget {
  const _ScanBanner({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Container(
    decoration: depthDecoration(ink, radius: 26),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const DepthIcon(
                Icons.qr_code_scanner_rounded,
                color: Colors.white,
                background: Color(0xFF286052),
                size: 52,
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scan & Search',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Scan a barcode or search any medicine',
                      style: TextStyle(color: Color(0xFFD2E6DB), fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_rounded, color: lime, size: 26),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> showWarningSettings(
  BuildContext context,
  PharmacyController controller,
) async {
  final days = TextEditingController(text: '${controller.settings.shortDays}'),
      months = TextEditingController(text: '${controller.settings.months}');
  String? error;
  int? selectedDays = [3, 5, 8, 10].contains(controller.settings.shortDays)
      ? controller.settings.shortDays
      : null;
  int? selectedMonths = [1, 2, 3].contains(controller.settings.months)
      ? controller.settings.months
      : null;
  final settings = await showDialog<WarningSettings>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Your expiry windows'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Short-expiry alert',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final value in [3, 5, 8, 10])
                    ChoiceChip(
                      label: Text('$value days'),
                      selected: selectedDays == value,
                      onSelected: (_) => setState(() {
                        selectedDays = value;
                        days.text = '$value';
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: days,
                onChanged: (_) => setState(() => selectedDays = null),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Custom short warning · days',
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Month-expiry alert',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final value in [1, 2, 3])
                    ChoiceChip(
                      label: Text('$value ${value == 1 ? 'month' : 'months'}'),
                      selected: selectedMonths == value,
                      onSelected: (_) => setState(() {
                        selectedMonths = value;
                        months.text = '$value';
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: months,
                onChanged: (_) => setState(() => selectedMonths = null),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Custom month warning · months',
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'One warning month = 30 days. Short-expiry entries are counted only in the day card.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: red, fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                final value = WarningSettings.fromJson({
                  'shortDays': int.tryParse(days.text),
                  'months': int.tryParse(months.text),
                });
                if (int.tryParse(days.text) == null ||
                    int.tryParse(months.text) == null)
                  throw const FormatException('Enter whole numbers.');
                Navigator.pop(ctx, value);
              } catch (e) {
                setState(
                  () => error = e.toString().replaceFirst(
                    'FormatException: ',
                    '',
                  ),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  // Dialog controllers are released after its route transition completes.
  Future<void>.delayed(const Duration(milliseconds: 300), () {
    days.dispose();
    months.dispose();
  });
  if (settings != null) {
    try {
      await controller.setWarnings(settings);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
