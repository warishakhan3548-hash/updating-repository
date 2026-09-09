import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(
  String id, {
  String name = 'Dolo',
  String strength = '650 mg',
  String batch = 'D650-A',
  String barcode = '8901000000650',
  int quantity = 10,
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'form': 'Tablet',
  'batchNumber': batch,
  'barcode': barcode,
  'quantity': quantity,
  'expiry': '2027-12',
  'revision': 1,
});

Medicine removed(
  String id, {
  String name = 'Dolo',
  String strength = '650 mg',
  String batch = 'D650-A',
  String barcode = '8901000000650',
  String reason = 'Damaged',
  DateTime? at,
}) => archiveMedicine(
  stock(
    id,
    name: name,
    strength: strength,
    batch: batch,
    barcode: barcode,
  ),
  reason: reason,
  at: at ?? DateTime.utc(2026, 9, 9, 10),
);

Future<PharmacyController> controllerWith(
  Map<String, Medicine> records,
) async {
  final controller = PharmacyController(
    MemoryInventoryStorage(InventorySnapshot(records: records)),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  group('one-database removed-stock search', () {
    test('fuzzy removed search excludes active inventory rows', () async {
      final archived = removed('archived');
      final active = stock(
        'active',
        name: 'Dolopar',
        strength: '500 mg',
        batch: 'ACTIVE-1',
        barcode: '8901111111111',
      );
      final controller = await controllerWith({
        archived.id: archived,
        active.id: active,
      });
      addTearDown(controller.dispose);

      final hits = await controller.searchArchived('Dlo 650');
      expect(hits.map((hit) => hit.id), contains(archived.id));
      expect(hits.map((hit) => hit.id), isNot(contains(active.id)));
    });

    test('exact product barcode returns every matching removed batch', () async {
      final oldA = removed('a', batch: 'A1');
      final oldB = removed(
        'b',
        batch: 'B1',
        at: DateTime.utc(2026, 9, 10, 8),
      );
      final controller = await controllerWith({oldA.id: oldA, oldB.id: oldB});
      addTearDown(controller.dispose);

      final hits = await controller.searchArchived('8901000000650');
      expect(hits.map((hit) => hit.id).toSet(), {'a', 'b'});
      expect(hits.every((hit) => hit.score == 1), isTrue);
    });
  });

  group('reviewed archived restore transaction', () {
    test('restores the exact archived row and remains undoable', () async {
      final archived = removed('a', reason: 'Returned');
      final controller = await controllerWith({'a': archived});
      addTearDown(controller.dispose);

      final review = controller.reviewArchivedRestore('a');
      expect(review.baseRevision, 0);
      expect(review.archiveReason, 'Returned');
      await controller.applyArchivedRestore(review);

      final restored = controller.snapshot.records['a']!;
      expect(restored.archived, isFalse);
      expect(restored.archiveReason, isEmpty);
      expect(restored.batchNumber, archived.batchNumber);
      expect(restored.quantity, archived.quantity);
      expect(controller.canUndo, isTrue);
      expect(controller.snapshot.events.first['label'], contains('Restored Dolo'));

      await controller.undo();
      final undone = controller.snapshot.records['a']!;
      expect(undone.archived, isTrue);
      expect(undone.archiveReason, 'Returned');
      expect(undone.archivedAt, archived.archivedAt);
    });

    test('stale review fails closed after any inventory revision change', () async {
      final archived = removed('a');
      final controller = await controllerWith({'a': archived});
      addTearDown(controller.dispose);

      final review = controller.reviewArchivedRestore('a');
      await controller.save(
        stock(
          'other',
          name: 'Crocin',
          strength: '500 mg',
          batch: 'C1',
          barcode: '8902222222222',
        ),
        expectedRevision: 0,
      );

      await expectLater(
        controller.applyArchivedRestore(review),
        throwsStateError,
      );
      expect(controller.snapshot.records['a']!.archived, isTrue);
    });

    test('integrity guard blocks restore when it would duplicate a physical lot', () async {
      final archived = removed('old');
      final active = stock('live');
      final controller = await controllerWith({
        archived.id: archived,
        active.id: active,
      });
      addTearDown(controller.dispose);

      final review = controller.reviewArchivedRestore('old');
      await expectLater(
        controller.applyArchivedRestore(review),
        throwsStateError,
      );
      expect(controller.snapshot.records['old']!.archived, isTrue);
      expect(controller.snapshot.records['live']!.archived, isFalse);
    });
  });
}
