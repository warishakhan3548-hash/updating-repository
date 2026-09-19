import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/attention.dart';
import '../domain/medicine.dart';
import '../domain/operations_plan.dart';
import '../domain/sale_history_integrity.dart';
import '../domain/stock_guidance.dart';
import '../domain/supplier.dart';
import '../domain/tracking.dart';
import 'pharmacy_controller.dart';

enum AarisAutopilotHealth { waiting, clear, attention, critical, degraded }


enum AarisAutopilotWorkQueueStatus { waiting, ready, degraded }

@immutable
class AarisAutopilotWorkQueue {
  const AarisAutopilotWorkQueue._({
    required this.status,
    required this.inventoryRevision,
    required this.day,
    required this.tasks,
  });

  factory AarisAutopilotWorkQueue.waiting({
    required int inventoryRevision,
    required String day,
  }) => AarisAutopilotWorkQueue._(
    status: AarisAutopilotWorkQueueStatus.waiting,
    inventoryRevision: inventoryRevision,
    day: day,
    tasks: const <StockGuidance>[],
  );

  factory AarisAutopilotWorkQueue.ready({
    required int inventoryRevision,
    required String day,
    required Iterable<StockGuidance> tasks,
  }) => AarisAutopilotWorkQueue._(
    status: AarisAutopilotWorkQueueStatus.ready,
    inventoryRevision: inventoryRevision,
    day: day,
    tasks: List<StockGuidance>.unmodifiable(tasks),
  );

  factory AarisAutopilotWorkQueue.degraded({
    required int inventoryRevision,
    required String day,
  }) => AarisAutopilotWorkQueue._(
    status: AarisAutopilotWorkQueueStatus.degraded,
    inventoryRevision: inventoryRevision,
    day: day,
    tasks: const <StockGuidance>[],
  );

  final AarisAutopilotWorkQueueStatus status;
  final int inventoryRevision;
  final String day;
  final List<StockGuidance> tasks;

  bool get isReady => status == AarisAutopilotWorkQueueStatus.ready;
}

/// Small immutable projection of the pharmacist's current operational workload.
///
/// This deliberately stores no inferred medicine facts and owns no write path.
/// It is a revision-bound digest over the same deterministic attention and
/// operations-plan engines already used elsewhere in Aaris Pharmacy.
@immutable
class AarisAutopilotDigest {
  const AarisAutopilotDigest._({
    required this.health,
    required this.inventoryRevision,
    required this.issueCount,
    required this.criticalCount,
    required this.highCount,
    required this.mediumCount,
    required this.lowCount,
    required this.blockedCount,
    required this.verificationCount,
    required this.nextTaskKey,
    required this.nextTaskTitle,
    required this.nextAction,
    required this.nextLane,
    required this.nextKind,
    required this.nextStockIds,
    required this.evaluatedAt,
  });

  factory AarisAutopilotDigest.waiting({int inventoryRevision = -1}) =>
      AarisAutopilotDigest._(
        health: AarisAutopilotHealth.waiting,
        inventoryRevision: inventoryRevision,
        issueCount: 0,
        criticalCount: 0,
        highCount: 0,
        mediumCount: 0,
        lowCount: 0,
        blockedCount: 0,
        verificationCount: 0,
        nextTaskKey: '',
        nextTaskTitle: '',
        nextAction: '',
        nextLane: '',
        nextKind: null,
        nextStockIds: const <String>[],
        evaluatedAt: null,
      );

  factory AarisAutopilotDigest.degraded({
    required int inventoryRevision,
    required DateTime evaluatedAt,
  }) => AarisAutopilotDigest._(
    health: AarisAutopilotHealth.degraded,
    inventoryRevision: inventoryRevision,
    issueCount: 0,
    criticalCount: 0,
    highCount: 0,
    mediumCount: 0,
    lowCount: 0,
    blockedCount: 0,
    verificationCount: 0,
    nextTaskKey: '',
    nextTaskTitle: '',
    nextAction: '',
    nextLane: '',
    nextKind: null,
    nextStockIds: const <String>[],
    evaluatedAt: evaluatedAt,
  );

  factory AarisAutopilotDigest.fromPlan({
    required int inventoryRevision,
    required Iterable<AttentionItem> items,
    required PharmacyOperationsPlan plan,
    required DateTime evaluatedAt,
  }) {
    var critical = 0, high = 0, medium = 0, low = 0, total = 0;
    for (final item in items) {
      total++;
      switch (item.severity) {
        case AttentionSeverity.critical:
          critical++;
        case AttentionSeverity.high:
          high++;
        case AttentionSeverity.medium:
          medium++;
        case AttentionSeverity.low:
          low++;
      }
    }

    final next = plan.nextStep;
    final health = total == 0
        ? AarisAutopilotHealth.clear
        : critical > 0
        ? AarisAutopilotHealth.critical
        : AarisAutopilotHealth.attention;

    return AarisAutopilotDigest._(
      health: health,
      inventoryRevision: inventoryRevision,
      issueCount: total,
      criticalCount: critical,
      highCount: high,
      mediumCount: medium,
      lowCount: low,
      blockedCount: plan.blockedCount,
      verificationCount: plan.verificationCount,
      nextTaskKey: next?.item.key ?? '',
      nextTaskTitle: next?.item.title ?? '',
      nextAction: next?.actionLabel ?? '',
      nextLane: next?.laneLabel ?? '',
      nextKind: next?.item.kind,
      nextStockIds: List<String>.unmodifiable(
        next?.item.stockIds ?? const <String>[],
      ),
      evaluatedAt: evaluatedAt,
    );
  }

  factory AarisAutopilotDigest.fromWorker({
    required int inventoryRevision,
    required Map<String, dynamic> result,
    required DateTime evaluatedAt,
  }) {
    final health = switch (result['health']) {
      'clear' => AarisAutopilotHealth.clear,
      'critical' => AarisAutopilotHealth.critical,
      'attention' => AarisAutopilotHealth.attention,
      _ => throw const FormatException('Invalid autopilot worker health.'),
    };
    final nextKindName = result['nextKind'];
    final nextKind = nextKindName == null || nextKindName == ''
        ? null
        : AttentionKind.values.byName(nextKindName as String);
    final stockIds = (result['nextStockIds'] as List<dynamic>? ?? const [])
        .cast<String>();

    int number(String key) {
      final value = result[key];
      if (value is! int || value < 0) {
        throw FormatException('Invalid autopilot worker $key.');
      }
      return value;
    }

    String text(String key) {
      final value = result[key];
      if (value is! String) {
        throw FormatException('Invalid autopilot worker $key.');
      }
      return value;
    }

    return AarisAutopilotDigest._(
      health: health,
      inventoryRevision: inventoryRevision,
      issueCount: number('issueCount'),
      criticalCount: number('criticalCount'),
      highCount: number('highCount'),
      mediumCount: number('mediumCount'),
      lowCount: number('lowCount'),
      blockedCount: number('blockedCount'),
      verificationCount: number('verificationCount'),
      nextTaskKey: text('nextTaskKey'),
      nextTaskTitle: text('nextTaskTitle'),
      nextAction: text('nextAction'),
      nextLane: text('nextLane'),
      nextKind: nextKind,
      nextStockIds: List<String>.unmodifiable(stockIds),
      evaluatedAt: evaluatedAt,
    );
  }

  final AarisAutopilotHealth health;
  final int inventoryRevision;
  final int issueCount;
  final int criticalCount;
  final int highCount;
  final int mediumCount;
  final int lowCount;
  final int blockedCount;
  final int verificationCount;
  final String nextTaskKey;
  final String nextTaskTitle;
  final String nextAction;
  final String nextLane;
  final AttentionKind? nextKind;
  final List<String> nextStockIds;
  final DateTime? evaluatedAt;

  bool get isReady => health != AarisAutopilotHealth.waiting;
  bool get hasUrgentWork => criticalCount > 0 || highCount > 0;
  bool get hasNextTask => nextTaskKey.isNotEmpty;
  bool get nextTaskIsExactStock => nextStockIds.length == 1;
  bool get needsProminentSignal =>
      health == AarisAutopilotHealth.degraded || hasUrgentWork;
  int get navigationBadgeCount =>
      health == AarisAutopilotHealth.degraded ? 1 : issueCount;

  String get accessibilitySummary {
    if (health == AarisAutopilotHealth.waiting) {
      return 'Aaris Autopilot is waiting for the Medicine Database.';
    }
    if (health == AarisAutopilotHealth.degraded) {
      return 'Aaris Autopilot could not complete its local safety check. Open the work queue to retry.';
    }
    if (issueCount == 0) {
      return 'Aaris Autopilot found no current attention items.';
    }
    final urgency = <String>[
      if (criticalCount > 0) '$criticalCount critical',
      if (highCount > 0) '$highCount high priority',
      if (mediumCount > 0) '$mediumCount medium priority',
    ].join(', ');
    final next = hasNextTask ? ' Next: $nextTaskTitle.' : '';
    return 'Aaris Autopilot found $issueCount attention items: $urgency.$next';
  }

  AarisAutopilotDigest _withEvaluatedAt(DateTime value) =>
      AarisAutopilotDigest._(
        health: health,
        inventoryRevision: inventoryRevision,
        issueCount: issueCount,
        criticalCount: criticalCount,
        highCount: highCount,
        mediumCount: mediumCount,
        lowCount: lowCount,
        blockedCount: blockedCount,
        verificationCount: verificationCount,
        nextTaskKey: nextTaskKey,
        nextTaskTitle: nextTaskTitle,
        nextAction: nextAction,
        nextLane: nextLane,
        nextKind: nextKind,
        nextStockIds: nextStockIds,
        evaluatedAt: value,
      );

  /// Ignores freshness-only metadata so a refresh that produces identical
  /// operational facts does not cause a pointless navigation/beacon repaint.
  ///
  /// [_publish] still swaps in the newest digest, so [inventoryRevision] and
  /// [evaluatedAt] remain current for callers that read them after the refresh.
  bool sameOperationalState(AarisAutopilotDigest other) =>
      health == other.health &&
      issueCount == other.issueCount &&
      criticalCount == other.criticalCount &&
      highCount == other.highCount &&
      mediumCount == other.mediumCount &&
      lowCount == other.lowCount &&
      blockedCount == other.blockedCount &&
      verificationCount == other.verificationCount &&
      nextTaskKey == other.nextTaskKey &&
      nextTaskTitle == other.nextTaskTitle &&
      nextAction == other.nextAction &&
      nextLane == other.nextLane &&
      nextKind == other.nextKind &&
      listEquals(nextStockIds, other.nextStockIds);
}

Medicine _operationalMedicineProjection(Medicine medicine) => Medicine(
  id: medicine.id,
  name: medicine.name,
  brand: medicine.brand,
  manufacturer: medicine.manufacturer,
  salt: medicine.salt,
  strength: medicine.strength,
  form: medicine.form,
  mfg: medicine.mfg,
  mfgMonthOnly: medicine.mfgMonthOnly,
  expiry: medicine.expiry,
  expiryMonthOnly: medicine.expiryMonthOnly,
  quantity: medicine.quantity,
  unitPricePaise: medicine.unitPricePaise,
  barcode: medicine.barcode,
  batchNumber: medicine.batchNumber,
  supplierId: medicine.supplierId,
  block: medicine.block,
  row: medicine.row,
  vertical: medicine.vertical,
  location: medicine.location,
  sold: medicine.sold,
  archived: medicine.archived,
  archivedAt: medicine.archivedAt,
  archiveReason: medicine.archiveReason,
  soldAt: medicine.soldAt,
  soldQuantity: medicine.soldQuantity,
  soldUnitPricePaise: medicine.soldUnitPricePaise,
  revision: medicine.revision,
);

Map<String, dynamic> _evaluateAutopilot(Map<String, dynamic> payload) {
  final records = (payload['records'] as List<dynamic>).cast<Medicine>();
  final allSales = (payload['sales'] as List<dynamic>).cast<SaleEvent>();
  final suppliers = (payload['suppliers'] as Map).cast<String, Supplier>();
  final settings = payload['settings'] as WarningSettings;
  final today = payload['today'] as DateTime;
  final start = today.subtract(const Duration(days: 30));
  final recordsById = <String, Medicine>{
    for (final medicine in records) medicine.id: medicine,
  };
  final activeById = <String, Medicine>{
    for (final medicine in records)
      if (!medicine.archived) medicine.id: medicine,
  };
  final recentSales = <SaleEvent>[];
  final saleHistorySales = <SaleEvent>[];
  for (final sale in allSales) {
    final saleDay = civilDay(sale.occurredAt);
    if (!saleDay.isBefore(start)) recentSales.add(sale);
    if (isSaleHistoryIntegrityCandidate(
      stock: activeById[sale.stockId],
      sale: sale,
      today: today,
    )) {
      saleHistorySales.add(sale);
    }
  }

  final tracking = TrackingStats(
    medicines: records,
    sales: recentSales,
    range: TrackingRange.lastDays(today, 30),
    today: today,
  );
  final report = PharmacyAttentionReport.build(
    medicines: records,
    settings: settings,
    today: today,
    reorder: tracking.reorder,
    sales: recentSales,
    saleHistorySales: saleHistorySales,
  );
  final plan = PharmacyOperationsPlan.build(
    items: report.items,
    medicines: records,
  );
  final orders = <String, ReorderSuggestion>{
    for (final order in tracking.reorder) order.productKey: order,
  };
  final dailyDemand = {
    for (final movement in tracking.movements.values)
      if (movement.demand != null) movement.key: movement.demand!,
  };
  final supplierTasks = supplierReturnGuidance(
    candidates: supplierReturnCandidates(
      medicines: records,
      suppliers: suppliers,
      today: today,
    ),
  );
  final supplierDueIds = supplierTasks.expand((task) => task.stockIds).toSet();
  final plannedTasks = <StockGuidance>[
    for (final step in plan.steps)
      StockGuidance.fromStep(
        step,
        records: recordsById,
        orders: orders,
        today: today,
        dailyDemand: dailyDemand,
      ),
  ];
  final tasks = <StockGuidance>[
    // A supplier return deadline is the more specific action. Do not show a
    // second generic short-expiry/expiry-waste card for the same exact stock.
    for (final task in plannedTasks)
      if (!(task.stockIds.any(supplierDueIds.contains) &&
          (task.step?.item.kind == AttentionKind.shortExpiry ||
              task.step?.item.kind == AttentionKind.expiryWastePressure)))
        task,
    ...supplierTasks,
    ...stockMovementGuidance(
      tracking: tracking,
      records: recordsById,
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
  final original = {for (var i = 0; i < tasks.length; i++) tasks[i].key: i};
  tasks.sort((a, b) {
    final order = priority(a).compareTo(priority(b));
    return order != 0 ? order : original[a.key]!.compareTo(original[b.key]!);
  });

  final next = plan.nextStep;
  return <String, dynamic>{
    'health': report.isEmpty
        ? 'clear'
        : report.critical > 0
        ? 'critical'
        : 'attention',
    'issueCount': report.items.length,
    'criticalCount': report.critical,
    'highCount': report.high,
    'mediumCount': report.medium,
    'lowCount': report.low,
    'blockedCount': plan.blockedCount,
    'verificationCount': plan.verificationCount,
    'nextTaskKey': next?.item.key ?? '',
    'nextTaskTitle': next?.item.title ?? '',
    'nextAction': next?.actionLabel ?? '',
    'nextLane': next?.laneLabel ?? '',
    'nextKind': next?.item.kind.name ?? '',
    'nextStockIds': List<String>.from(next?.item.stockIds ?? const <String>[]),
    'tasks': tasks,
  };
}

/// Event-driven, read-only pharmacist-work supervisor.
///
/// It continuously coalesces Medicine Database changes into the existing
/// deterministic Needs Attention + dependency planner. Heavy operational
/// analysis runs away from the UI isolate, never calls a stock mutation API, and
/// publishes only if the exact immutable snapshot and civil day are still current.
/// At most one worker runs at a time; newer writes invalidate old output and
/// collapse into a single fresh pass.
class AarisAutopilotSupervisor extends ChangeNotifier {
  AarisAutopilotSupervisor(
    this.controller, {
    this.debounce = const Duration(milliseconds: 120),
    bool startImmediately = true,
  }) : _digest = AarisAutopilotDigest.waiting(
         inventoryRevision: controller.snapshot.revision,
       ),
       _workQueue = ValueNotifier<AarisAutopilotWorkQueue>(
         AarisAutopilotWorkQueue.waiting(
           inventoryRevision: controller.snapshot.revision,
           day: dateText(controller.today),
         ),
       ) {
    _observedSnapshot = controller.snapshot;
    _observedRevision = controller.snapshot.revision;
    _observedDay = dateText(controller.today);
    _observedReady = controller.ready;
    controller.addListener(_onControllerChanged);
    // Product hosts can defer the first full-dataset projection until after
    // their initial frame. Standalone/domain callers retain eager startup.
    if (startImmediately) refreshNow();
  }

  final PharmacyController controller;
  final Duration debounce;

  AarisAutopilotDigest _digest;
  AarisAutopilotDigest get digest => _digest;

  final ValueNotifier<AarisAutopilotWorkQueue> _workQueue;

  /// Full pharmacist work cards produced by the same background evaluation as
  /// [digest]. This has a separate notifier so detailed queue refreshes never
  /// force the Home beacon/navigation badge to repaint.
  ValueListenable<AarisAutopilotWorkQueue> get workQueue => _workQueue;

  /// Returns the background queue only when it belongs to the exact live
  /// inventory revision and civil business day. Consumers must not each invent
  /// their own freshness rule: one ownership point keeps route guards, Brain
  /// shortcuts and future queue surfaces fail-closed in the same way.
  AarisAutopilotWorkQueue? get currentWorkQueue {
    final source = controller.snapshot;
    final current = _workQueue.value;
    if (!current.isReady ||
        !identical(_workQueueSource, source) ||
        current.inventoryRevision != source.revision ||
        current.day != dateText(controller.today)) {
      return null;
    }
    return current;
  }

  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  bool _computing = false;
  bool _rerunRequested = false;
  bool _lifecycleActive = true;
  Object? _observedSnapshot;
  Object? _workQueueSource;
  int _observedRevision = -1;
  String _observedDay = '';
  bool _observedReady = false;

  bool get lifecycleActive => _lifecycleActive;

  /// Pauses read-only background planning outside the foreground lifecycle. Any
  /// in-flight result is generation-invalidated and therefore cannot publish a
  /// stale badge/task after the app was backgrounded. Resume always requests one
  /// fresh pass from the authoritative controller snapshot.
  void setLifecycleActive(bool active) {
    if (_disposed) return;
    if (_lifecycleActive == active) {
      if (active) refreshNow();
      return;
    }

    _lifecycleActive = active;
    _timer?.cancel();
    _timer = null;
    ++_generation;
    _rerunRequested = false;
    if (active) refreshNow();
  }

  void _onControllerChanged() {
    final source = controller.snapshot;
    final revision = source.revision;
    final day = dateText(controller.today);
    final ready = controller.ready;
    if (identical(source, _observedSnapshot) &&
        revision == _observedRevision &&
        day == _observedDay &&
        ready == _observedReady) {
      return;
    }
    _observedSnapshot = source;
    _observedRevision = revision;
    _observedDay = day;
    _observedReady = ready;
    _schedule();
  }

  void _schedule() {
    if (_disposed || !_lifecycleActive) return;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = Timer(debounce, () => _launch(generation));
  }

  /// Re-evaluates at the next safe microtask boundary. This is used after app
  /// resume and initial database load, while normal write bursts are debounced.
  void refreshNow() {
    if (_disposed || !_lifecycleActive) return;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    scheduleMicrotask(() => _launch(generation));
  }

  void _launch(int generation) {
    if (_disposed || !_lifecycleActive || generation != _generation) return;
    if (_computing) {
      _rerunRequested = true;
      return;
    }
    _computing = true;
    unawaited(
      _rebuild(generation).whenComplete(() {
        _computing = false;
        if (_disposed || !_rerunRequested) return;
        _rerunRequested = false;
        refreshNow();
      }),
    );
  }

  Future<void> _rebuild(int generation) async {
    if (_disposed || !_lifecycleActive || generation != _generation) return;

    final source = controller.snapshot;
    final revision = source.revision;
    final today = controller.today;
    final day = dateText(today);
    if (!controller.ready) {
      _publishWorkQueue(
        AarisAutopilotWorkQueue.waiting(
          inventoryRevision: revision,
          day: day,
        ),
        source: source,
      );
      _publish(AarisAutopilotDigest.waiting(inventoryRevision: revision));
      return;
    }

    final currentQueue = _workQueue.value;
    if (currentQueue.isReady &&
        identical(_workQueueSource, source) &&
        currentQueue.inventoryRevision == revision &&
        currentQueue.day == day &&
        _digest.isReady &&
        _digest.health != AarisAutopilotHealth.degraded &&
        _digest.inventoryRevision == revision) {
      // Operational planning is deterministic for one immutable snapshot and
      // civil day. Route-open/resume refreshes should update freshness metadata
      // without rebuilding the full payload or starting another isolate.
      _digest = _digest._withEvaluatedAt(controller.clock());
      return;
    }

    try {
      // Build a lightweight immutable handoff from one authoritative snapshot.
      // Notes/OCR can be very large and are irrelevant to deterministic
      // operational planning, so they never cross this isolate boundary.
      // The same worker now also builds the screen-ready work queue: opening
      // "आज के काम" never repeats full inventory analytics on the UI isolate.
      final payload = <String, dynamic>{
        'records': <Medicine>[
          for (final medicine in source.records.values)
            _operationalMedicineProjection(medicine),
        ],
        'sales': source.sales.values.toList(growable: false),
        'suppliers': Map<String, Supplier>.from(source.suppliers),
        'settings': source.settings,
        'today': today,
      };

      final result = await compute(_evaluateAutopilot, payload);
      if (_disposed || !_lifecycleActive || generation != _generation) return;
      if (!identical(controller.snapshot, source) ||
          controller.snapshot.revision != revision ||
          dateText(controller.today) != day) {
        _rerunRequested = true;
        return;
      }

      _publishWorkQueue(
        AarisAutopilotWorkQueue.ready(
          inventoryRevision: revision,
          day: day,
          tasks: (result['tasks'] as List<dynamic>).cast<StockGuidance>(),
        ),
        source: source,
      );
      _publish(
        AarisAutopilotDigest.fromWorker(
          inventoryRevision: revision,
          result: result,
          evaluatedAt: controller.clock(),
        ),
      );
    } catch (_) {
      if (_disposed || !_lifecycleActive || generation != _generation) return;
      final liveSource = controller.snapshot;
      final liveRevision = liveSource.revision;
      final liveDay = dateText(controller.today);
      _publishWorkQueue(
        AarisAutopilotWorkQueue.degraded(
          inventoryRevision: liveRevision,
          day: liveDay,
        ),
        source: liveSource,
      );
      _publish(
        AarisAutopilotDigest.degraded(
          inventoryRevision: liveRevision,
          evaluatedAt: controller.clock(),
        ),
      );
    }
  }

  void _publishWorkQueue(
    AarisAutopilotWorkQueue next, {
    required Object source,
  }) {
    if (_disposed) return;
    final current = _workQueue.value;

    // Snapshot identity is part of freshness. The controller can reload a
    // different authoritative snapshot at the same numeric revision; reusing a
    // queue across that boundary could expose stale pharmacist work.
    if (identical(_workQueueSource, source) &&
        current.status == next.status &&
        current.inventoryRevision == next.inventoryRevision &&
        current.day == next.day) {
      return;
    }
    _workQueueSource = source;
    _workQueue.value = next;
  }

  void _publish(AarisAutopilotDigest next) {
    final changed = !_digest.sameOperationalState(next);
    _digest = next;
    if (changed && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    controller.removeListener(_onControllerChanged);
    _workQueue.dispose();
    super.dispose();
  }
}
