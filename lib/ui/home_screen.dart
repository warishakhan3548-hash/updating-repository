import 'package:flutter/material.dart';

import '../state/pharmacy_controller.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
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
      final records = controller.list(SearchScope.all);
      final attention = [
        ...controller.list(SearchScope.expired),
        ...controller.list(SearchScope.shortExpiry),
        ...controller.list(SearchScope.monthExpiry),
      ].take(4).toList();
      return ListView(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 30),
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(Icons.add_rounded, color: lime, size: 30),
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
                      'YOUR INVENTORY, IN ORDER',
                      style: TextStyle(
                        fontSize: 9.5,
                        letterSpacing: 1.5,
                        color: muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Expiry warning settings',
                onPressed: () => showWarningSettings(context, controller),
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              const StatusPill('●  Saved on this device'),
              const Spacer(),
              Text(
                dateText(controller.today),
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Text(
            'A calmer day.\nA clearer inventory.',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: ink,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: ink.withValues(alpha: .17),
                  blurRadius: 26,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'A PLACE FOR EVERY MEDICINE',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.2,
                              color: Color(0xFFB9CFC2),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            '${controller.stats.uniqueMedicines}',
                            style: const TextStyle(
                              fontSize: 42,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              height: 1.1,
                              letterSpacing: -1.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'medicines in your care',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFFC6D6CE),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const _PillArt(),
                  ],
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: lime,
                    foregroundColor: ink,
                    minimumSize: const Size(double.infinity, 54),
                  ),
                  onPressed: () => _open(context, SearchScope.all),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('Scan & Search'),
                ),
              ],
            ),
          ),
          SectionHeading(
            'Your stock, at a glance',
            action: IconButton(
              tooltip: 'Set day and month windows',
              onPressed: () => showWarningSettings(context, controller),
              icon: const Icon(Icons.tune_rounded, size: 20),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final tiles = [
                _OverviewTile(
                  title: '${controller.settings.shortDays} Days Left',
                  caption: 'Short expiry',
                  count: controller.list(SearchScope.shortExpiry).length,
                  icon: Icons.timelapse_rounded,
                  color: green,
                  background: const Color(0xFFE9F1DB),
                  onTap: () => _open(context, SearchScope.shortExpiry),
                ),
                _OverviewTile(
                  title:
                      '${controller.settings.months} ${controller.settings.months == 1 ? 'Month' : 'Months'} Left',
                  caption: 'Month warning',
                  count: controller.list(SearchScope.monthExpiry).length,
                  icon: Icons.date_range_rounded,
                  color: green,
                  background: const Color(0xFFEDF3ED),
                  onTap: () => _open(context, SearchScope.monthExpiry),
                ),
                _OverviewTile(
                  title: 'Sold Medicines',
                  caption: 'Ready to reorder',
                  count: controller.list(SearchScope.sold).length,
                  icon: Icons.check_circle_outline_rounded,
                  color: amber,
                  background: const Color(0xFFFFF1CF),
                  onTap: () => _open(context, SearchScope.sold),
                ),
                _OverviewTile(
                  title: 'Expired Medicines',
                  caption: 'Review your stock',
                  count: controller.list(SearchScope.expired).length,
                  icon: Icons.event_busy_rounded,
                  color: red,
                  background: const Color(0xFFFBE9E5),
                  onTap: () => _open(context, SearchScope.expired),
                ),
              ];
              final columns = constraints.maxWidth > 620
                  ? 4
                  : MediaQuery.textScalerOf(context).scale(14) > 22
                  ? 1
                  : 2;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: tiles
                    .map(
                      (tile) => SizedBox(
                        width:
                            (constraints.maxWidth - 12 * (columns - 1)) /
                            columns,
                        child: tile,
                      ),
                    )
                    .toList(),
              );
            },
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
              message: 'Add a name now. Expiry, location and price can be filled in whenever you have them.',
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
                    child: Text(
                      'No expired or short-expiry stock to review today.',
                    ),
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

class _PillArt extends StatelessWidget {
  const _PillArt();
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 86,
    height: 100,
    child: Center(
      child: Transform.rotate(
        angle: .55,
        child: Container(
          width: 43,
          height: 86,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(40),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .3),
                blurRadius: 15,
                offset: const Offset(9, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0xFFF8FFE7),
                          Color(0xFFC2E977),
                          Color(0xFF9CC257),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0xFFFFFFFF),
                          Color(0xFFE0EADF),
                          Color(0xFFA5B4A9),
                        ],
                      ),
                    ),
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
  Widget build(BuildContext context) => Material(
    color: background,
    borderRadius: BorderRadius.circular(22),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 23),
                const Spacer(),
                Icon(Icons.north_east_rounded, color: color, size: 18),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '$count',
              style: TextStyle(
                color: color,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            const SizedBox(height: 3),
            Text(caption, style: const TextStyle(fontSize: 10.5, color: muted)),
          ],
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
