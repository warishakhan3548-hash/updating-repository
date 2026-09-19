import 'package:flutter/material.dart';

import '../state/pharmacy_controller.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import 'design.dart';
import 'search_screen.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.onDatabase,
  });
  final PharmacyController controller;
  final VoidCallback onDatabase;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int? _pendingShortDays;
  int? _pendingMonths;
  int _shortIntentGeneration = 0;
  int _monthIntentGeneration = 0;

  PharmacyController get controller => widget.controller;
  VoidCallback get onDatabase => widget.onDatabase;

  void _open(BuildContext context, SearchScope scope) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SearchScreen(controller: controller, scope: scope),
        ),
      );

  Future<void> _setShortDays(BuildContext context, int value) async {
    final effective = _pendingShortDays ?? controller.settings.shortDays;
    if (value == effective) return;
    final owner = controller;
    final generation = ++_shortIntentGeneration;
    setState(() => _pendingShortDays = value);
    try {
      await owner.setShortWarningDays(value);
    } catch (e) {
      if (context.mounted &&
          identical(controller, owner) &&
          generation == _shortIntentGeneration) {
        showError(context, e);
      }
    } finally {
      // A completed older request must never retire a newer equal-valued intent.
      if (generation == _shortIntentGeneration) {
        if (mounted) {
          setState(() => _pendingShortDays = null);
        } else {
          _pendingShortDays = null;
        }
      }
    }
  }

  Future<void> _setMonths(BuildContext context, int value) async {
    final effective = _pendingMonths ?? controller.settings.months;
    if (value == effective) return;
    final owner = controller;
    final generation = ++_monthIntentGeneration;
    setState(() => _pendingMonths = value);
    try {
      await owner.setWarningMonths(value);
    } catch (e) {
      if (context.mounted &&
          identical(controller, owner) &&
          generation == _monthIntentGeneration) {
        showError(context, e);
      }
    } finally {
      if (generation == _monthIntentGeneration) {
        if (mounted) {
          setState(() => _pendingMonths = null);
        } else {
          _pendingMonths = null;
        }
      }
    }
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    _pendingShortDays = null;
    _pendingMonths = null;
    _shortIntentGeneration++;
    _monthIntentGeneration++;
  }

  @override
  Widget build(BuildContext context) => ActiveListenableBuilder(
    listenable: controller,
    // Home renders medicine facts, warning settings and the civil day only.
    // Supplier/activity/sale-only snapshots must stay frame-quiet here.
    rebuildToken: () => (
      controller.snapshot.records,
      controller.snapshot.settings,
      controller.today,
    ),
    builder: (context, _) {
      // Rebuild only for Home's visible dependencies. While a warning-window
      // write is pending, pass that optimistic preference to the controller so
      // title, counts, attention rows and row styling acknowledge the tap
      // together without moving projection rules or stock scans into the UI.
      final authoritativeSettings = controller.settings;
      final hasPendingWarningWindow =
          _pendingShortDays != null || _pendingMonths != null;
      final visibleSettings = hasPendingWarningWindow
          ? WarningSettings.fromJson(<String, dynamic>{
              'shortDays':
                  _pendingShortDays ?? authoritativeSettings.shortDays,
              'months': _pendingMonths ?? authoritativeSettings.months,
            })
          : authoritativeSettings;
      final projection = controller.homeProjectionFor(visibleSettings);
      final attention = projection.attention;
      final visibleShortDays = visibleSettings.shortDays;
      final visibleMonths = visibleSettings.months;
      return ListView(
        key: const PageStorageKey('home-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        children: [
          Row(
            children: [
              const DepthIcon(
                Icons.add_rounded,
                color: primarySoft,
                background: primary,
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
            ],
          ),
          const SizedBox(height: 22),
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
                      '$visibleShortDays ${visibleShortDays == 1 ? 'Day' : 'Days'} Left',
                  caption: 'Short expiry',
                  count: projection.shortExpiryCount,
                  icon: Icons.timelapse_rounded,
                  color: primary,
                  background: primarySoft,
                  selector: _WarningSelector(
                    label: '${visibleShortDays}d',
                    busy: _pendingShortDays != null,
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
                      '$visibleMonths ${visibleMonths == 1 ? 'Month' : 'Months'} Left',
                  caption: 'Month warning',
                  count: projection.monthExpiryCount,
                  icon: Icons.calendar_month_rounded,
                  color: accent,
                  background: accentSoft,
                  selector: _WarningSelector(
                    label: '${visibleMonths}mo',
                    busy: _pendingMonths != null,
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
                  count: projection.soldCount,
                  icon: Icons.check_circle_outline_rounded,
                  color: amber,
                  background: warningSoft,
                  onTap: () => _open(context, SearchScope.sold),
                ),
                _OverviewTile(
                  title: 'Expired Medicines',
                  caption: 'Review your stock',
                  count: projection.expiredCount,
                  icon: Icons.event_busy_rounded,
                  color: red,
                  background: errorSoft,
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
                        fontWeight: caption ? FontWeight.w600 : FontWeight.w800,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    textScaler: scaler,
                  )..layout(maxWidth: cardWidth - 34);
                  if (painter.height > maxHeight) maxHeight = painter.height;
                  painter.dispose();
                }
                return maxHeight;
              }

              final selectorHeight =
                  (scaler.scale(10.5) > 16 ? scaler.scale(10.5) : 16) + 30;
              final topRowHeight = selectorHeight > 42 ? selectorHeight : 42;
              final height =
                  62 +
                  topRowHeight +
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
                        '${projection.uniqueMedicines} medicines in your care',
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
                  size: 48,
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
          if (projection.isEmpty)
            EmptyState(
              title: 'Start with your first medicine',
              message:
                  'Add its name now. Fill in expiry, location and price when you have them.',
              action: RaisedActionButton(
                icon: Icons.add_rounded,
                label: 'Add medicine',
                onPressed: () => openEditor(context, controller),
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
                settings: visibleSettings,
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
  Widget build(BuildContext context) => GlassPanel(
    radius: 22,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  DepthIcon(
                    icon,
                    color: color,
                    background: background,
                    size: 40,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child:
                          selector ??
                          Icon(
                            Icons.north_east_rounded,
                            size: 20,
                            color: muted,
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
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: color,
                  fontWeight: FontWeight.w600,
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
    this.busy = false,
  });

  final String label;
  final bool busy;
  final List<int> values;
  final String Function(int) valueLabel;
  final ValueChanged<int> onSelected;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
    tooltip: busy
        ? 'Warning window is saving. You can choose another value.'
        : 'Change warning window',
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
      elevation: .35,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: ink,
                fontSize: 10.5,
                height: 1,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 5),
          if (busy)
            const Icon(
              Icons.sync_rounded,
              size: 14,
              color: primary,
            )
          else
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
    tint: const Color(0xFFF0F5FF),
    accentColor: primary,
    shadowColor: primary,
    radius: 22,
    elevation: 1.12,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        splashColor: primary.withValues(alpha: .10),
        highlightColor: primary.withValues(alpha: .05),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const DepthIcon(
                Icons.qr_code_scanner_rounded,
                color: primary,
                background: primarySoft,
                size: 48,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scan & Search',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: primaryDeep,
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Scan a pack. Speak a name. Find your stock.',
                      style: TextStyle(
                        color: muted,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.arrow_forward_rounded,
                color: primary,
                size: 22,
              ),
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
  final settings = await showDialog<WarningSettings>(
    context: context,
    builder: (_) => _WarningSettingsDialog(initial: controller.settings),
  );
  if (settings != null) {
    try {
      await controller.setWarnings(settings);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class _WarningSettingsDialog extends StatefulWidget {
  const _WarningSettingsDialog({required this.initial});

  final WarningSettings initial;

  @override
  State<_WarningSettingsDialog> createState() => _WarningSettingsDialogState();
}

class _WarningSettingsDialogState extends State<_WarningSettingsDialog> {
  late final TextEditingController _days;
  late final TextEditingController _months;
  late int? _selectedDays;
  late int? _selectedMonths;
  String? _error;

  @override
  void initState() {
    super.initState();
    _days = TextEditingController(text: '${widget.initial.shortDays}');
    _months = TextEditingController(text: '${widget.initial.months}');
    _selectedDays = const [3, 5, 8, 10].contains(widget.initial.shortDays)
        ? widget.initial.shortDays
        : null;
    _selectedMonths = const [1, 2, 3].contains(widget.initial.months)
        ? widget.initial.months
        : null;
  }

  @override
  void dispose() {
    _days.dispose();
    _months.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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
              for (final value in const [3, 5, 8, 10])
                ChoiceChip(
                  label: Text('$value days'),
                  selected: _selectedDays == value,
                  onSelected: (_) => setState(() {
                    _selectedDays = value;
                    _days.text = '$value';
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _days,
            onChanged: (_) => setState(() => _selectedDays = null),
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
              for (final value in const [1, 2, 3])
                ChoiceChip(
                  label: Text('$value ${value == 1 ? 'month' : 'months'}'),
                  selected: _selectedMonths == value,
                  onSelected: (_) => setState(() {
                    _selectedMonths = value;
                    _months.text = '$value';
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _months,
            onChanged: (_) => setState(() => _selectedMonths = null),
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
          if (_error != null)
            Text(_error!, style: const TextStyle(color: red, fontSize: 12)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final shortDays = int.tryParse(_days.text);
            final months = int.tryParse(_months.text);
            if (shortDays == null || months == null) {
              throw const FormatException('Enter whole numbers.');
            }
            final value = WarningSettings.fromJson({
              'shortDays': shortDays,
              'months': months,
            });
            Navigator.pop(context, value);
          } catch (e) {
            setState(
              () => _error = e.toString().replaceFirst(
                'FormatException: ',
                '',
              ),
            );
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
