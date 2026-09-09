import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/operational_context.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(String id, {int quantity = 10}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'batchNumber': 'B-$id',
  'quantity': quantity,
  'expiry': '2027-12',
  'revision': 1,
});

Future<PharmacyController> controllerForContext() async {
  final controller = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  group('Aaris operational context', () {
    test('keeps live operational facts while exact medicine identity is stable', () async {
      final controller = await controllerForContext();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);

      controller.rememberOperationalTarget('a');
      expect(controller.operationalTargetId, 'a');
      expect(controller.operationalTarget?.quantity, 10);

      final live = controller.snapshot.records['a']!;
      final updated = Medicine.fromJson({
        ...live.toJson(),
        'quantity': 7,
        'revision': live.revision + 1,
      });
      await controller.save(updated, expectedRevision: 1);

      // Context never caches operational facts such as quantity. It re-resolves
      // the exact row through the authoritative current snapshot every time.
      expect(controller.operationalTarget?.quantity, 7);
      expect(controller.operationalTargetId, 'a');
    });

    test('identity-changing edits invalidate stale this/same-one context', () async {
      final controller = await controllerForContext();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);
      controller.rememberOperationalTarget('a');

      final live = controller.snapshot.records['a']!;
      await controller.save(
        live.patch({'batchNumber': 'CORRECTED-BATCH'}),
        expectedRevision: 1,
      );

      // The stock ID still exists, but a prior conversational reference was
      // anchored to different physical identity facts. Aaris must ask the user
      // to choose the exact row again instead of silently following the edit.
      expect(controller.operationalTarget, isNull);
      expect(controller.operationalTargetId, isNull);
    });

    test('removed or unknown targets fail closed instead of becoming stale', () async {
      final controller = await controllerForContext();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);
      controller.rememberOperationalTarget('a');

      await controller.archive('a', 'Correction', expectedRevision: 1);
      expect(controller.operationalTarget, isNull);
      expect(controller.operationalTargetId, isNull);

      expect(
        () => controller.rememberOperationalTarget('missing'),
        throwsStateError,
      );
    });

    test('clearing another ID cannot erase the current exact target', () async {
      final controller = await controllerForContext();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);
      await controller.save(stock('b'), expectedRevision: 1);
      controller.rememberOperationalTarget('b');

      controller.clearOperationalTarget('a');
      expect(controller.operationalTarget?.id, 'b');

      controller.clearOperationalTarget('b');
      expect(controller.operationalTarget, isNull);
    });
  });
}
