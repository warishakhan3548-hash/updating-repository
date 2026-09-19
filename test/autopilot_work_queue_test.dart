import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'autopilot publishes reusable work cards for the exact revision and day',
    () async {
      final medicine = Medicine.fromJson(<String, dynamic>{
        'id': 'queue-stock',
        'name': 'Dolo',
        'strength': '650mg',
        'form': 'Tablet',
        'quantity': 12,
      });
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(
            records: <String, Medicine>{medicine.id: medicine},
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
        final queue = supervisor.workQueue.value;
        if (queue.isReady &&
            queue.inventoryRevision == controller.snapshot.revision) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final first = supervisor.workQueue.value;
      expect(first.isReady, isTrue);
      expect(first.inventoryRevision, controller.snapshot.revision);
      expect(first.day, '2026-09-10');
      expect(
        first.tasks.any((task) => task.stockIds.contains(medicine.id)),
        isTrue,
      );

      await controller.save(
        medicine.patch(<String, dynamic>{'location': 'Rack A'}),
        expectedRevision: controller.snapshot.revision,
      );
      for (var attempt = 0; attempt < 50; attempt++) {
        if (supervisor.workQueue.value.inventoryRevision ==
            controller.snapshot.revision) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(
        supervisor.workQueue.value.inventoryRevision,
        controller.snapshot.revision,
      );
      expect(supervisor.workQueue.value.day, '2026-09-10');
    },
  );
}
