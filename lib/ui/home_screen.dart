import 'dart:async';

import 'package:flutter/material.dart';

import '../state/autopilot_supervisor.dart';
import '../state/pharmacy_controller.dart';
import '../domain/home_projection.dart';
import '../domain/stock_guidance.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import 'design.dart';
import 'search_screen.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.autopilot,
    required this.onOpenWorkQueue,
  });
  final PharmacyController controller;
  final AarisAutopilotSupervisor autopilot;
  final VoidCallback onOpenWorkQueue;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int? _pendingShortDays;
  int? _pendingMonths;
  int _shortIntentGeneration = 0;
  int _monthIntentGeneration = 0;
  bool _routeOpening = false;

  PharmacyController get controller => widget.controller;

  Future<void> _runExclusiveRoute(Future<void> Function() action) async {
    if (_routeOpening || !mounted) return;
    _routeOpening = true;
    try {
      await action();
    } finally {
      _routeOpening = false;
    }
  }

  void _open(BuildContext context, SearchScope scope) {
    unawaited(
      _runExclusiveRoute(
        () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => SearchScreen(controller: controller, scope: scope),
          ),
        ),
      ),
    );
  }

  void _edit([Medicine? record]) {
    unawaited(
      _runExclusiveRoute(
        () => openEditor(context, controller, record: record),
      ),
    );
  }

  void _openWarningSettings(WarningSettings initial) {
    unawaited(
      _runExclusiveRoute(
        () => showWarningSettings(context, controller, initial: initial),
      ),
    );
  }

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
    // Home listens to the exact presentation dependency epoch rather than
    // every medicine-map identity. Quantity/price-only writes can therefore
    // stay frame-quiet while visible facts, warning policy and the civil day
    // still repaint immediately.
    rebuildToken: () => (controller.homeProjectionEpoch, controller.today),
    builder: (context, _) {
      // Rebuild only when Home-visible inventory meaning or the civil day
      // changes. The controller memoizes the authoritative projection. While a
      // warning-window write is
      // pending, derive one transient projection from that same snapshot so the
      // title, counts, attention rows and row styling all acknowledge the tap
      // together instead of mixing new controls with old persisted semantics.
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
      final projection = hasPendingWarningWindow
          ? HomeInventoryProjection.build(
              medicines: controller.records,
              settings: visibleSettings,
              today: controller.today,
            )
          : controller.homeProjection;
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
                    onCustom: () => _openWarningSettings(visibleSettings),
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
                    onCustom: () => _openWarningSettings(visibleSettings),
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
                  onPressed: _edit,
                  icon: Icons.add_circle_outline_rounded,
                  size: 48,
                ),
              ],
            ),
          ),
          _TodayWorkPreview(
            autopilot: widget.autopilot,
            onOpenWorkQueue: widget.onOpenWorkQueue,
            emptyInventory: projection.isEmpty,
            onAddMedicine: _edit,
          ),
        ],
      );
    },
  );
}

class _TodayWorkPreview extends StatelessWidget {
  const _TodayWorkPreview({
    required this.autopilot,
    required this.onOpenWorkQueue,
    required this.emptyInventory,
    required this.onAddMedicine,
  });

  final AarisAutopilotSupervisor autopilot;
  final VoidCallback onOpenWorkQueue;
  final bool emptyInventory;
  final VoidCallback onAddMedicine;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AarisAutopilotWorkQueue>(
    valueListenable: autopilot.workQueue,
    builder: (context, queue, _) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeading(
            'आज के काम',
            action: TextButton.icon(
              onPressed: onOpenWorkQueue,
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: const Text('सभी देखें'),
            ),
          ),
          if (emptyInventory)
            EmptyState(
              title: 'Start with your first medicine',
              message:
                  'Add its name now. Fill in expiry, location and price when you have them.',
              action: RaisedActionButton(
                icon: Icons.add_rounded,
                label: 'Add medicine',
                onPressed: onAddMedicine,
              ),
            )
          else if (!identical(autopilot.currentWorkQueue, queue))
            Surface(
              child: Row(
                children: [
                  if (queue.status == AarisAutopilotWorkQueueStatus.degraded)
                    const Icon(Icons.sync_problem_rounded, color: amber)
                  else
                    const Icon(Icons.sync_rounded, color: primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      queue.status == AarisAutopilotWorkQueueStatus.degraded
                          ? 'काम की सूची अभी तैयार नहीं हो सकी। खोलकर दोबारा जाँचें।'
                          : 'आज के काम अपडेट हो रहे हैं…',
                    ),
                  ),
                ],
              ),
            )
          else
            _ReadyTodayWork(
              tasks: queue.tasks,
              onOpenWorkQueue: onOpenWorkQueue,
            ),
        ],
      );
    },
  );
}

class _ReadyTodayWork extends StatelessWidget {
  const _ReadyTodayWork({
    required this.tasks,
    required this.onOpenWorkQueue,
  });

  final List<StockGuidance> tasks;
  final VoidCallback onOpenWorkQueue;

  @override
  Widget build(BuildContext context) {
    final operational = tasks
        .where((task) => task.group != StockTaskGroup.movement)
        .toList(growable: false);
    final advisory = tasks
        .where((task) => task.group == StockTaskGroup.movement)
        .toList(growable: false);
    final source = operational.isNotEmpty ? operational : advisory;
    final preview = source.take(3).toList(growable: false);

    if (source.isEmpty) {
      return const Surface(
        child: Row(
          children: [
            Icon(Icons.check_circle_outline_rounded, color: green),
            SizedBox(width: 12),
            Expanded(child: Text('अभी कोई जरूरी काम नहीं है।')),
          ],
        ),
      );
    }

    final summary = operational.isNotEmpty
        ? advisory.isEmpty
              ? '${operational.length} काम · प्राथमिकता के क्रम में'
              : '${operational.length} काम · ${advisory.length} सुझाव'
        : '${advisory.length} सुझाव · अभी कोई जरूरी correction नहीं';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            summary,
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ),
        for (final task in preview)
          _HomeWorkRow(task: task, onTap: onOpenWorkQueue),
        if (source.length > preview.length)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+${source.length - preview.length} और · सभी काम देखने के लिए ऊपर टैप करें',
              style: const TextStyle(color: muted, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

class _HomeWorkRow extends StatelessWidget {
  const _HomeWorkRow({required this.task, required this.onTap});

  final StockGuidance task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = task.critical
        ? red
        : task.blocked
        ? amber
        : task.group == StockTaskGroup.movement
        ? accent
        : primary;
    final icon = switch (task.group) {
      StockTaskGroup.urgent => Icons.timer_outlined,
      StockTaskGroup.order => Icons.add_shopping_cart_rounded,
      StockTaskGroup.supplier => Icons.assignment_return_outlined,
      StockTaskGroup.details => Icons.edit_note_rounded,
      StockTaskGroup.movement => Icons.insights_outlined,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: .12)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.action,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: color, size: 20),
            ],
          ),
        ),
      ),
    );
  }
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

class _WarningSettingsEdit {
  const _WarningSettingsEdit({
    required this.settings,
    required this.shortDaysChanged,
    required this.monthsChanged,
  });

  final WarningSettings settings;
  final bool shortDaysChanged;
  final bool monthsChanged;
}

Future<void> showWarningSettings(
  BuildContext context,
  PharmacyController controller, {
  WarningSettings? initial,
}) async {
  final baseline = initial ?? controller.settings;
  final edit = await showDialog<_WarningSettingsEdit>(
    context: context,
    builder: (_) => _WarningSettingsDialog(initial: baseline),
  );
  if (edit != null) {
    try {
      await controller.updateWarningFields(
        shortDays: edit.shortDaysChanged ? edit.settings.shortDays : null,
        months: edit.monthsChanged ? edit.settings.months : null,
      );
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
  bool _shortDaysChanged = false;
  bool _monthsChanged = false;
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
                    _shortDaysChanged = true;
                    _selectedDays = value;
                    _days.text = '$value';
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _days,
            onChanged: (_) => setState(() {
              _shortDaysChanged = true;
              _selectedDays = null;
            }),
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
                    _monthsChanged = true;
                    _selectedMonths = value;
                    _months.text = '$value';
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _months,
            onChanged: (_) => setState(() {
              _monthsChanged = true;
              _selectedMonths = null;
            }),
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
            Navigator.pop(
              context,
              _WarningSettingsEdit(
                settings: value,
                shortDaysChanged: _shortDaysChanged,
                monthsChanged: _monthsChanged,
              ),
            );
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
