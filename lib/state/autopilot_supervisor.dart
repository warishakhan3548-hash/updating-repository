import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/attention.dart';
import '../domain/medicine.dart';
import '../domain/operations_plan.dart';
import '../domain/sale_history_integrity.dart';
import '../domain/tracking.dart';
import 'pharmacy_controller.dart';

enum AarisAutopilotHealth { waiting, clear, attention, critical, degraded }

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

  /// Ignores [evaluatedAt] so a manual refresh that produces identical facts
  /// does not cause a pointless application-wide repaint.
  bool sameOperationalState(AarisAutopilotDigest other) =>
      health == other.health &&
      inventoryRevision == other.inventoryRevision &&
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

Map<String, dynamic> _operationalMedicineJson(Medicine medicine) {
  final json = medicine.toJson();
  // Notes/OCR can be large and are irrelevant to deterministic operational
  // attention checks. Do not copy those private free-text blobs across isolates.
  json['notes'] = '';
  json['ocrText'] = '';
  return json;
}

Map<String, dynamic> _evaluateAutopilot(Map<String, dynamic> payload) {
  final records = <Medicine>[
    for (final raw in payload['records'] as List<dynamic>)
      Medicine.fromJson(Map<String, dynamic>.from(raw as Map)),
  ];
  final sales = <SaleEvent>[
    for (final raw in payload['sales'] as List<dynamic>)
      SaleEvent.fromJson(Map<String, dynamic>.from(raw as Map)),
  ];
  final saleHistorySales = <SaleEvent>[
    for (final raw in payload['saleHistorySales'] as List<dynamic>)
      SaleEvent.fromJson(Map<String, dynamic>.from(raw as Map)),
  ];
  final settings = WarningSettings.fromJson(
    Map<String, dynamic>.from(payload['settings'] as Map),
  );
  final today = DateTime.parse(payload['today'] as String);
  final tracking = TrackingStats(
    medicines: records,
    sales: sales,
    range: TrackingRange.lastDays(today, 30),
    today: today,
  );
  final report = PharmacyAttentionReport.build(
    medicines: records,
    settings: settings,
    today: today,
    reorder: tracking.reorder,
    sales: sales,
    saleHistorySales: saleHistorySales,
  );
  final plan = PharmacyOperationsPlan.build(
    items: report.items,
    medicines: records,
  );
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
  };
}

/// Event-driven, read-only pharmacist-work supervisor.
///
/// It continuously coalesces Medicine Database changes into the existing
/// deterministic Needs Attention + dependency planner. Heavy operational
/// analysis runs away from the UI isolate, never calls a stock mutation API, and
/// publishes only if the exact inventory revision is still current. At most one
/// worker runs at a time; newer writes invalidate old output and collapse into a
/// single fresh pass.
class AarisAutopilotSupervisor extends ChangeNotifier {
  AarisAutopilotSupervisor(
    this.controller, {
    this.debounce = const Duration(milliseconds: 120),
  }) : _digest = AarisAutopilotDigest.waiting(
         inventoryRevision: controller.snapshot.revision,
       ) {
    _observedRevision = controller.snapshot.revision;
    _observedDay = dateText(controller.today);
    controller.addListener(_onControllerChanged);
    refreshNow();
  }

  final PharmacyController controller;
  final Duration debounce;

  AarisAutopilotDigest _digest;
  AarisAutopilotDigest get digest => _digest;

  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  bool _computing = false;
  bool _rerunRequested = false;
  bool _lifecycleActive = true;
  int _observedRevision = -1;
  String _observedDay = '';

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
    final revision = controller.snapshot.revision;
    final day = dateText(controller.today);
    if (revision == _observedRevision && day == _observedDay) return;
    _observedRevision = revision;
    _observedDay = day;
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

    final revision = controller.snapshot.revision;
    if (!controller.ready) {
      _publish(AarisAutopilotDigest.waiting(inventoryRevision: revision));
      return;
    }

    try {
      final today = controller.today;
      final start = today.subtract(const Duration(days: 29));
      final activeById = <String, Medicine>{
        for (final medicine in controller.records)
          if (!medicine.archived) medicine.id: medicine,
      };
      final recentSales = <Map<String, dynamic>>[];
      final saleHistorySales = <Map<String, dynamic>>[];
      for (final sale in controller.sales) {
        final saleDay = civilDay(sale.occurredAt);
        if (!saleDay.isBefore(start) && !saleDay.isAfter(today)) {
          recentSales.add(sale.toJson());
        }
        if (isSaleHistoryIntegrityCandidate(
          stock: activeById[sale.stockId],
          sale: sale,
          today: today,
        )) {
          saleHistorySales.add(sale.toJson());
        }
      }

      // Capture only operational fields. Large OCR/notes text is intentionally
      // excluded because it is irrelevant to integrity, FEFO, risk and reorder.
      // Recent sales drive velocity/risk; the second list contains only exact
      // full-history anomalies that can become immutable-ledger safety tasks.
      final payload = <String, dynamic>{
        'records': <Map<String, dynamic>>[
          for (final medicine in controller.records)
            _operationalMedicineJson(medicine),
        ],
        'sales': recentSales,
        'saleHistorySales': saleHistorySales,
        'settings': controller.settings.toJson(),
        'today': today.toIso8601String(),
      };

      final result = await compute(_evaluateAutopilot, payload);
      if (_disposed || !_lifecycleActive || generation != _generation) return;
      if (controller.snapshot.revision != revision) {
        _rerunRequested = true;
        return;
      }

      _publish(
        AarisAutopilotDigest.fromWorker(
          inventoryRevision: revision,
          result: result,
          evaluatedAt: controller.clock(),
        ),
      );
    } catch (_) {
      if (_disposed || !_lifecycleActive || generation != _generation) return;
      _publish(
        AarisAutopilotDigest.degraded(
          inventoryRevision: controller.snapshot.revision,
          evaluatedAt: controller.clock(),
        ),
      );
    }
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
    super.dispose();
  }
}
