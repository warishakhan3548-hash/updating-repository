import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/attention.dart';
import '../domain/operations_plan.dart';
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

  String get accessibilitySummary {
    if (health == AarisAutopilotHealth.waiting) {
      return 'Aaris Autopilot is waiting for the Medicine Database.';
    }
    if (health == AarisAutopilotHealth.degraded) {
      return 'Aaris Autopilot could not complete its local safety check.';
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

/// Event-driven, read-only pharmacist-work supervisor.
///
/// It continuously coalesces Medicine Database changes into the existing
/// deterministic Needs Attention + dependency planner. It never calls a stock
/// mutation API. Reorder evidence is derived from the same 30-day sales window
/// used by the operational surfaces, and a revision change during calculation
/// invalidates the result before publication.
class AarisAutopilotSupervisor extends ChangeNotifier {
  AarisAutopilotSupervisor(
    this.controller, {
    this.debounce = const Duration(milliseconds: 120),
  }) : _digest = AarisAutopilotDigest.waiting(
         inventoryRevision: controller.snapshot.revision,
       ) {
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

  void _onControllerChanged() => _schedule();

  void _schedule() {
    if (_disposed) return;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = Timer(debounce, () => _rebuild(generation));
  }

  /// Re-evaluates at the next safe microtask boundary. This is used after app
  /// resume and initial database load, while normal write bursts are debounced.
  void refreshNow() {
    if (_disposed) return;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    scheduleMicrotask(() => _rebuild(generation));
  }

  void _rebuild(int generation) {
    if (_disposed || generation != _generation) return;

    final revision = controller.snapshot.revision;
    if (!controller.ready) {
      _publish(AarisAutopilotDigest.waiting(inventoryRevision: revision));
      return;
    }

    try {
      // Materialize once so every engine in this pass sees one coherent local
      // snapshot even if an unrelated write is queued while calculation runs.
      final records = controller.records.toList(growable: false);
      final sales = controller.sales.toList(growable: false);
      final today = controller.today;
      final settings = controller.settings;
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
      );
      final plan = PharmacyOperationsPlan.build(
        items: report.items,
        medicines: records,
      );

      if (_disposed || generation != _generation) return;
      if (controller.snapshot.revision != revision) {
        // Never publish advice calculated from a stale inventory revision.
        refreshNow();
        return;
      }

      _publish(
        AarisAutopilotDigest.fromPlan(
          inventoryRevision: revision,
          items: report.items,
          plan: plan,
          evaluatedAt: controller.clock(),
        ),
      );
    } catch (_) {
      if (_disposed || generation != _generation) return;
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
