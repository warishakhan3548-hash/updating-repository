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

  Future<void> _setShortDays(BuildContext context, int value) async {
    if (value == controller.settings.shortDays) return;
    try {
      final settings = WarningSettings.fromJson({
        'shortDays': value,
        'months': controller.settings.months,
      });
      await controller.setWarnings(settings);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _setMonths(BuildContext context, int value) async {
    if (value == controller.settings.months) return;
    try {
      final settings = WarningSettings.fromJson({
        'shortDays': controller.settings.shortDays,
        'months': value,
      });
      await controller.setWarnings(settings);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

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
              GlassIconButton(
                tooltip: 'Expiry warning settings',
                onPressed: () => showWarningSettings(context, controller),
                icon: Icons.tune_rounded,
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
                  selector: _WarningSelector(
                    label:
                        '${controller.settings.shortDays} ${controller.settings.shortDays == 1 ? 'Day' : 'Days'}',
                    values: const [3, 5, 8, 10],
                    valueLabel: (value) =>
                        '$value ${value == 1 ? 'Day' : 'Days'}',
                    onSelected: (value) => _setShortDays(context, value),
                    onCustom: () => showWarningSettings(context, controller),
                  ),
                  onTap: () => _open(context, SearchScope.shortExpiry),
                ),
                _OverviewTile(
                  title:
                      '${controller.settings.months} ${controller.settings.months == 1 ? 'Month' : 'Months'} Left',
                  caption: 'Month warning',
                  count: month.length,
                  icon: Icons.calendar_month_rounded,
                  color: const Color(0xFF167EA6),
                  background: const Color(0xFFE2F3FC),
                  selector: _WarningSelector(
                    label:
                        '${controller.settings.months} ${controller.settings.months == 1 ? 'Month' : 'Months'}',
                    values: const [1, 2, 3],
                    valueLabel: (value) =>
                        '$value ${value == 1 ? 'Month' : 'Months'}',
                    onSelected: (value) => _setMonths(context, value),
                    onCustom: () => showWarningSettings(context, controller),
                  ),
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

              // Keep every overview card exactly the same measured height.
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
          GlassPanel(
            tint: Colors.white,
            radius: 24,
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
                GlassIconButton(
                  tooltip: 'Add medicine',
                  onPressed: () => openEditor(context, controller),
                  icon: Icons.add_circle_outline_rounded,
                  size: 40,
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
    this.selector,
  });
  final String title, caption;
  final int count;
  final IconData icon;
  final Color color, background;
  final VoidCallback onTap;
  final Widget? selector;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$title, $count medicines. $caption',
    child: GlassPanel(
      tint: background,
      radius: 25,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(25),
          child: Stack(
            children: [
              Positioned(
                left: -30,
                top: -52,
                child: IgnorePointer(
                  child: Container(
                    width: 155,
                    height: 125,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(70),
                      gradient: RadialGradient(
                        colors: [
                          Colors.white.withValues(alpha: .72),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -12,
                bottom: -14,
                child: ExcludeSemantics(
                  child: Transform.rotate(
                    angle: -.25,
                    child: Icon(
                      icon,
                      size: 86,
                      color: color.withValues(alpha: .075),
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
                        GlassPanel(
                          tint: Color.alphaBlend(
                            color.withValues(alpha: .14),
                            background,
                          ),
                          radius: 14,
                          blurSigma: 0,
                          elevation: .55,
                          child: SizedBox(
                            width: 42,
                            height: 42,
                            child: Icon(icon, color: color, size: 23),
                          ),
                        ),
                        const Spacer(),
                        selector ??
                            GlassPanel(
                              tint: background,
                              radius: 18,
                              blurSigma: 0,
                              elevation: .45,
                              child: SizedBox(
                                width: 36,
                                height: 36,
                                child: Icon(
                                  Icons.north_east_rounded,
                                  color: color,
                                  size: 20,
                                ),
                              ),
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
                          shadows: [
                            Shadow(
                              color: Colors.white.withValues(alpha: .72),
                              blurRadius: 10,
                              offset: const Offset(0, -1),
                            ),
                          ],
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
  );
}

class _WarningSelector extends StatelessWidget {
  const _WarningSelector({
    required this.label,
    required this.values,
    required this.valueLabel,
    required this.onSelected,
    required this.onCustom,
  });

  final String label;
  final List<int> values;
  final String Function(int) valueLabel;
  final ValueChanged<int> onSelected;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
    tooltip: 'Change warning window',
    padding: EdgeInsets.zero,
    offset: const Offset(0, 8),
    onSelected: (value) {
      if (value == -1) {
        onCustom();
      } else {
        onSelected(value);
      }
    },
    itemBuilder: (context) => [
      for (final value in values)
        PopupMenuItem<int>(value: value, child: Text(valueLabel(value))),
      const PopupMenuDivider(),
      const PopupMenuItem<int>(
        value: -1,
        child: Row(
          children: [
            Icon(Icons.tune_rounded, size: 18),
            SizedBox(width: 9),
            Text('Custom…'),
          ],
        ),
      ),
    ],
    child: GlassPanel(
      tint: Colors.white,
      radius: 999,
      blurSigma: 0,
      elevation: .35,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: ink,
              fontSize: 10.5,
              height: 1,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 3),
          const Icon(Icons.expand_more_rounded, size: 16, color: ink),
        ],
      ),
    ),
  );
}

class _ScanBanner extends StatelessWidget {
  const _ScanBanner({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GlassPanel(
    tint: ink,
    radius: 27,
    dark: true,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(27),
        child: Stack(
          children: [
            Positioned(
              right: -42,
              top: -58,
              child: IgnorePointer(
                child: Container(
                  width: 170,
                  height: 170,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        lime.withValues(alpha: .13),
                        lime.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  GlassPanel(
                    tint: const Color(0xFF286052),
                    radius: 17,
                    dark: true,
                    blurSigma: 0,
                    elevation: .55,
                    child: const SizedBox(
                      width: 52,
                      height: 52,
                      child: Icon(
                        Icons.qr_code_scanner_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
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
                          style: TextStyle(
                            color: Color(0xFFD2E6DB),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassPanel(
                    tint: lime,
                    radius: 22,
                    blurSigma: 0,
                    elevation: .55,
                    child: const SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        color: ink,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
                    int.tryParse(months.text) == null) {
                  throw const FormatException('Enter whole numbers.');
                }
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
