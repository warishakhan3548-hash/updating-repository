import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/operations_plan.dart';
import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AarisAutopilotDigest', () {
    test('surfaces the dependency planner next safe task, not raw list order', () {
      const expired = AttentionItem(
        key: 'expired:s1',
        kind: AttentionKind.expiredStock,
        severity: AttentionSeverity.critical,
        title: 'Dolo · expired',
        detail: 'Keep out of dispensing.',
        stockIds: <String>['s1'],
      );
      const reorder = AttentionItem(
        key: 'reorder:dolo',
        kind: AttentionKind.urgentReorder,
        severity: AttentionSeverity.high,
        title: 'Dolo · urgent reorder',
        detail: 'Review purchasing.',
        stockIds: <String>['s1'],
        productKey: 'dolo',
      );

      final plan = PharmacyOperationsPlan.build(
        items: const <AttentionItem>[reorder, expired],
        medicines: const <Medicine>[],
      );
      final digest = AarisAutopilotDigest.fromPlan(
        inventoryRevision: 41,
        items: const <AttentionItem>[reorder, expired],
        plan: plan,
        evaluatedAt: DateTime(2026, 9, 10),
      );

      expect(digest.health, AarisAutopilotHealth.critical);
      expect(digest.issueCount, 2);
      expect(digest.criticalCount, 1);
      expect(digest.highCount, 1);
      expect(digest.nextTaskKey, 'expired:s1');
      expect(digest.nextKind, AttentionKind.expiredStock);
      expect(digest.nextTaskIsExactStock, isTrue);
    });

    test('reports verification blockers without promoting blocked purchasing', () {
      const quantity = AttentionItem(
        key: 'quantity:s1',
        kind: AttentionKind.unknownQuantity,
        severity: AttentionSeverity.high,
        title: 'Dolo · quantity not recorded',
        detail: 'Count physical stock first.',
        stockIds: <String>['s1'],
        productKey: 'dolo',
      );
      const reorder = AttentionItem(
        key: 'reorder:dolo',
        kind: AttentionKind.urgentReorder,
        severity: AttentionSeverity.high,
        title: 'Dolo · urgent reorder',
        detail: 'Review purchasing.',
        stockIds: <String>['s1'],
        productKey: 'dolo',
      );

      final plan = PharmacyOperationsPlan.build(
        items: const <AttentionItem>[reorder, quantity],
        medicines: const <Medicine>[],
      );
      final digest = AarisAutopilotDigest.fromPlan(
        inventoryRevision: 42,
        items: const <AttentionItem>[reorder, quantity],
        plan: plan,
        evaluatedAt: DateTime(2026, 9, 10),
      );

      expect(plan.blockedCount, 1);
      expect(digest.blockedCount, 1);
      expect(digest.verificationCount, 1);
      expect(digest.nextTaskKey, 'quantity:s1');
      expect(digest.nextKind, AttentionKind.unknownQuantity);
      expect(digest.nextAction, contains('Count the physical stock'));
    });

    test('clear inventory produces a quiet digest', () {
      final plan = PharmacyOperationsPlan.build(
        items: const <AttentionItem>[],
        medicines: const <Medicine>[],
      );
      final digest = AarisAutopilotDigest.fromPlan(
        inventoryRevision: 43,
        items: const <AttentionItem>[],
        plan: plan,
        evaluatedAt: DateTime(2026, 9, 10),
      );

      expect(digest.health, AarisAutopilotHealth.clear);
      expect(digest.issueCount, 0);
      expect(digest.hasUrgentWork, isFalse);
      expect(digest.hasNextTask, isFalse);
      expect(digest.needsProminentSignal, isFalse);
      expect(digest.navigationBadgeCount, 0);
      expect(digest.accessibilitySummary, contains('no current attention items'));
    });

    test('identical operational facts do not repaint merely for a new timestamp', () {
      const item = AttentionItem(
        key: 'expiry:s1',
        kind: AttentionKind.unknownExpiry,
        severity: AttentionSeverity.medium,
        title: 'Dolo · expiry not recorded',
        detail: 'Verify expiry.',
        stockIds: <String>['s1'],
      );
      final plan = PharmacyOperationsPlan.build(
        items: const <AttentionItem>[item],
        medicines: const <Medicine>[],
      );
      final first = AarisAutopilotDigest.fromPlan(
        inventoryRevision: 44,
        items: const <AttentionItem>[item],
        plan: plan,
        evaluatedAt: DateTime(2026, 9, 10, 9),
      );
      final second = AarisAutopilotDigest.fromPlan(
        inventoryRevision: 44,
        items: const <AttentionItem>[item],
        plan: plan,
        evaluatedAt: DateTime(2026, 9, 10, 10),
      );

      expect(first.sameOperationalState(second), isTrue);
    });

    test('worker result keeps exact next-task identity across isolate boundary', () {
      final digest = AarisAutopilotDigest.fromWorker(
        inventoryRevision: 45,
        evaluatedAt: DateTime(2026, 9, 10, 10),
        result: <String, dynamic>{
          'health': 'attention',
          'issueCount': 3,
          'criticalCount': 0,
          'highCount': 1,
          'mediumCount': 2,
          'lowCount': 0,
          'blockedCount': 1,
          'verificationCount': 1,
          'nextTaskKey': 'barcode:890123',
          'nextTaskTitle': 'Barcode 890123 needs identity review',
          'nextAction': 'Verify the physical packs.',
          'nextLane': 'Verify facts',
          'nextKind': AttentionKind.barcodeConflict.name,
          'nextStockIds': <String>['s1', 's2'],
        },
      );

      expect(digest.inventoryRevision, 45);
      expect(digest.nextKind, AttentionKind.barcodeConflict);
      expect(digest.nextStockIds, <String>['s1', 's2']);
      expect(digest.nextTaskIsExactStock, isFalse);
      expect(digest.navigationBadgeCount, 3);
    });

    test('autopilot calculation failure is fail-visible, never a false clear', () {
      final digest = AarisAutopilotDigest.degraded(
        inventoryRevision: 46,
        evaluatedAt: DateTime(2026, 9, 10, 10),
      );

      expect(digest.health, AarisAutopilotHealth.degraded);
      expect(digest.issueCount, 0);
      expect(digest.needsProminentSignal, isTrue);
      expect(digest.navigationBadgeCount, 1);
      expect(digest.accessibilitySummary, contains('retry'));
    });
  });
}
