import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReloadableInventoryStorage implements InventoryStorage {
  _ReloadableInventoryStorage(this.snapshot);

  InventorySnapshot snapshot;

  @override
  Future<InventorySnapshot> load() async => snapshot;

  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) =>
      Future<InventorySnapshot>.error(
        UnsupportedError('This test storage is read-only.'),
      );

  @override
  Future<void> close() async {}
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for Autopilot to publish the expected snapshot.');
}

void main() {
  test(
    'same-revision reload invalidates stale work and automatically recomputes',
    () async {
      final storage = _ReloadableInventoryStorage(InventorySnapshot());
      final controller = PharmacyController(
        storage,
        clock: () => DateTime(2026, 9, 20, 10),
        backgroundSearch: false,
      );
      await controller.initialize();

      final supervisor = AarisAutopilotSupervisor(
        controller,
        debounce: const Duration(milliseconds: 30),
        startImmediately: false,
      );
      addTearDown(() {
        supervisor.dispose();
        controller.dispose();
      });

      supervisor.refreshNow();
      await _waitFor(() => supervisor.currentWorkQueue != null);
      final firstQueue = supervisor.currentWorkQueue!;
      expect(firstQueue.tasks, isEmpty);

      const stockId = 'same-revision-reload-stock';
      storage.snapshot = InventorySnapshot(
        revision: controller.snapshot.revision,
        records: <String, Medicine>{
          stockId: Medicine(
            id: stockId,
            name: 'Reload Safety Medicine',
            strength: '500mg',
            form: 'Tablet',
            quantity: 12,
          ),
        },
      );

      await controller.initialize();

      expect(
        supervisor.currentWorkQueue,
        isNull,
        reason:
            'A queue from a different snapshot object must fail closed even when the numeric revision is unchanged.',
      );

      await _waitFor(
        () =>
            supervisor.currentWorkQueue?.tasks.any(
              (task) => task.stockIds.contains(stockId),
            ) ??
            false,
      );

      expect(supervisor.currentWorkQueue, isNot(same(firstQueue)));
    },
  );
}
