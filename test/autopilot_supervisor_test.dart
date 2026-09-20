import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/operations_plan.dart';
import 'package:aaris_pharmacy/domain/stock_guidance.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AarisAutopilotDigest', () {
    test(
      'surfaces the dependency planner next safe task, not raw list order',
      () {
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
      },
    );

    test(
      'reports verification blockers without promoting blocked purchasing',
      () {
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
      },
    );

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
      expect(
        digest.accessibilitySummary,
        contains('no current attention items'),
      );
    });

    test(
      'identical operational facts do not repaint merely for a new timestamp',
      () {
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
      },
    );

    test(
      'revision-only freshness updates keep unchanged operational UI quiet',
      () {
        final plan = PharmacyOperationsPlan.build(
          items: const <AttentionItem>[],
          medicines: const <Medicine>[],
        );
        final first = AarisAutopilotDigest.fromPlan(
          inventoryRevision: 44,
          items: const <AttentionItem>[],
          plan: plan,
          evaluatedAt: DateTime(2026, 9, 10, 9),
        );
        final second = AarisAutopilotDigest.fromPlan(
          inventoryRevision: 45,
          items: const <AttentionItem>[],
          plan: plan,
          evaluatedAt: DateTime(2026, 9, 10, 10),
        );

        expect(first.inventoryRevision, isNot(second.inventoryRevision));
        expect(first.sameOperationalState(second), isTrue);
      },
    );

    test(
      'worker result keeps exact next-task identity across isolate boundary',
      () {
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
      },
    );

    test(
      'autopilot calculation failure is fail-visible, never a false clear',
      () {
        final digest = AarisAutopilotDigest.degraded(
          inventoryRevision: 46,
          evaluatedAt: DateTime(2026, 9, 10, 10),
        );

        expect(digest.health, AarisAutopilotHealth.degraded);
        expect(digest.issueCount, 0);
        expect(digest.needsProminentSignal, isTrue);
        expect(digest.navigationBadgeCount, 1);
        expect(digest.accessibilitySummary, contains('retry'));
      },
    );

    test(
      'future recovered sale history remains visible outside demand window',
      () async {
        final medicine = Medicine.fromJson(<String, dynamic>{
          'id': 'future-sale-stock',
          'name': 'Dolo',
          'strength': '650mg',
          'form': 'Tablet',
          'mfg': '2026-01-01',
          'expiry': '2027-01-31',
          'quantity': 10,
          'location': 'Rack A',
        });
        final sale = SaleEvent(
          id: 'future-sale-event',
          stockId: medicine.id,
          medicineName: medicine.name,
          strength: medicine.strength,
          form: medicine.form,
          salt: medicine.salt,
          quantity: 1,
          occurredAt: DateTime(2026, 9, 11, 9),
        );
        final controller = PharmacyController(
          MemoryInventoryStorage(
            InventorySnapshot(
              records: <String, Medicine>{medicine.id: medicine},
              sales: <String, SaleEvent>{sale.id: sale},
            ),
          ),
          clock: () => DateTime(2026, 9, 10, 10),
          backgroundSearch: false,
        );
        await controller.initialize();
        final supervisor = AarisAutopilotSupervisor(
          controller,
          debounce: Duration.zero,
        );
        addTearDown(() {
          supervisor.dispose();
          controller.dispose();
        });

        for (var attempt = 0; attempt < 50; attempt++) {
          if (supervisor.digest.isReady &&
              supervisor.digest.inventoryRevision ==
                  controller.snapshot.revision) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(supervisor.digest.highCount, greaterThanOrEqualTo(1));
        expect(supervisor.digest.nextKind, AttentionKind.futureSaleHistory);
      },
    );

    test(
      'movement-only advice keeps health clear without inventing a next task',
      () async {
        final medicine = Medicine.fromJson(<String, dynamic>{
          'id': 'movement-only',
          'name': 'Paracetamol',
          'strength': '500mg',
          'form': 'Tablet',
          'expiry': '2027-12-31',
          'quantity': 100,
          'location': 'Rack A',
        });
        final sales = <String, SaleEvent>{
          for (var day = 1; day <= 20; day++)
            'movement-sale-$day': SaleEvent(
              id: 'movement-sale-$day',
              stockId: medicine.id,
              medicineName: medicine.name,
              strength: medicine.strength,
              form: medicine.form,
              salt: medicine.salt,
              quantity: 1,
              occurredAt: DateTime(2026, 9, day, 10),
            ),
        };
        final controller = PharmacyController(
          MemoryInventoryStorage(
            InventorySnapshot(
              records: <String, Medicine>{medicine.id: medicine},
              sales: sales,
            ),
          ),
          clock: () => DateTime(2026, 9, 20, 12),
          backgroundSearch: false,
        );
        await controller.initialize();
        final supervisor = AarisAutopilotSupervisor(
          controller,
          debounce: Duration.zero,
        );
        addTearDown(() {
          supervisor.dispose();
          controller.dispose();
        });

        for (var attempt = 0; attempt < 50; attempt++) {
          if (supervisor.currentWorkQueue != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(supervisor.digest.health, AarisAutopilotHealth.clear);
        expect(supervisor.digest.issueCount, 0);
        expect(supervisor.digest.hasNextTask, isFalse);
        expect(
          supervisor.currentWorkQueue?.tasks.any(
            (task) => task.group == StockTaskGroup.movement,
          ),
          isTrue,
        );
      },
    );

    test('deferred startup waits for an explicit refresh', () async {
      final controller = PharmacyController(
        MemoryInventoryStorage(),
        clock: () => DateTime(2026, 9, 10, 10),
        backgroundSearch: false,
      );
      await controller.initialize();
      final supervisor = AarisAutopilotSupervisor(
        controller,
        debounce: Duration.zero,
        startImmediately: false,
      );
      addTearDown(() {
        supervisor.dispose();
        controller.dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(supervisor.digest.health, AarisAutopilotHealth.waiting);

      supervisor.refreshNow();
      for (var attempt = 0; attempt < 50; attempt++) {
        if (supervisor.digest.isReady) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(supervisor.digest.health, AarisAutopilotHealth.clear);
    });

    test(
      'initial load wakes supervisor even when revision and day stay unchanged',
      () async {
        final controller = PharmacyController(
          MemoryInventoryStorage(),
          clock: () => DateTime(2026, 9, 10, 10),
          backgroundSearch: false,
        );
        final supervisor = AarisAutopilotSupervisor(
          controller,
          debounce: Duration.zero,
        );
        addTearDown(() {
          supervisor.dispose();
          controller.dispose();
        });

        // Let the constructor's pre-initialization pass settle as waiting.
        await Future<void>.delayed(Duration.zero);
        expect(supervisor.digest.health, AarisAutopilotHealth.waiting);
        expect(supervisor.digest.inventoryRevision, 0);

        // Loading an empty revision-0 database changes readiness only. The
        // supervisor must still schedule a fresh worker pass.
        await controller.initialize();
        for (var attempt = 0; attempt < 50; attempt++) {
          if (supervisor.digest.isReady) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(supervisor.digest.health, AarisAutopilotHealth.clear);
        expect(supervisor.digest.inventoryRevision, 0);
      },
    );


    test(
      'current work queue is exposed only for the exact live revision and day',
      () async {
        final controller = PharmacyController(
          MemoryInventoryStorage(),
          clock: () => DateTime(2026, 9, 10, 10),
          backgroundSearch: false,
        );
        await controller.initialize();
        final supervisor = AarisAutopilotSupervisor(
          controller,
          debounce: const Duration(hours: 1),
          startImmediately: false,
        );
        addTearDown(() {
          supervisor.dispose();
          controller.dispose();
        });

        expect(supervisor.currentWorkQueue, isNull);
        supervisor.refreshNow();
        for (var attempt = 0; attempt < 50; attempt++) {
          if (supervisor.currentWorkQueue != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          supervisor.currentWorkQueue?.inventoryRevision,
          controller.snapshot.revision,
        );

        await controller.save(
          Medicine.fromJson(<String, dynamic>{
            'id': 'freshness-row',
            'name': 'Dolo',
            'quantity': 1,
          }),
          expectedRevision: controller.snapshot.revision,
        );

        // The old queue remains available for rendering while the debounced
        // worker catches up, but action consumers must fail closed immediately.
        expect(supervisor.workQueue.value.isReady, isTrue);
        expect(supervisor.currentWorkQueue, isNull);

        supervisor.refreshNow();
        for (var attempt = 0; attempt < 50; attempt++) {
          if (supervisor.currentWorkQueue?.inventoryRevision ==
              controller.snapshot.revision) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          supervisor.currentWorkQueue?.inventoryRevision,
          controller.snapshot.revision,
        );
      },
    );

    test(
      'background suspension drops stale work and resume catches up once',
      () async {
        final controller = PharmacyController(
          MemoryInventoryStorage(),
          clock: () => DateTime(2026, 9, 10, 10),
          backgroundSearch: false,
        );
        await controller.initialize();
        final supervisor = AarisAutopilotSupervisor(
          controller,
          debounce: Duration.zero,
        );
        addTearDown(() {
          supervisor.dispose();
          controller.dispose();
        });

        // Suspend before the constructor's scheduled microtask can publish.
        supervisor.setLifecycleActive(false);
        expect(supervisor.lifecycleActive, isFalse);

        await controller.save(
          Medicine.fromJson(<String, dynamic>{
            'id': 'foreground-test',
            'name': 'Dolo',
            'quantity': 1,
          }),
          expectedRevision: controller.snapshot.revision,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(supervisor.digest.inventoryRevision, 0);

        supervisor.setLifecycleActive(true);
        for (var attempt = 0; attempt < 50; attempt++) {
          if (supervisor.digest.inventoryRevision ==
              controller.snapshot.revision) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(supervisor.lifecycleActive, isTrue);
        expect(
          supervisor.digest.inventoryRevision,
          controller.snapshot.revision,
        );
      },
    );
  });
}
