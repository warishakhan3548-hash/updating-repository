import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/automation_guard.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _lot(
  String id, {
  String expiry = '2027-01',
  String barcode = '8901234567890',
  String batch = 'LOT-17',
  int quantity = 10,
  String notes = '',
}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650mg',
  'form': 'Tablet',
  'expiry': expiry,
  'barcode': barcode,
  'batchNumber': batch,
  'quantity': quantity,
  'notes': notes,
});

InventorySnapshot _snapshot(Medicine a, Medicine b) => InventorySnapshot(
  records: {a.id: a, b.id: b},
);

void main() {
  final today = DateTime(2026, 9, 10);

  group('authoritative physical-lot integrity firewall', () {
    test('detects a newly introduced strongly anchored lot contradiction', () {
      final a = _lot('a', expiry: '2027-01');
      final b = _lot('b', expiry: '2027-01');
      final changed = b.patch({'expiry': '2027-02'});

      final conflicts = newlyIntroducedLotConflicts(
        before: [a, b],
        after: [a, changed],
        today: today,
      );

      expect(conflicts, hasLength(1));
      expect(conflicts.single.stockIds.toSet(), {'a', 'b'});
    });

    test('blocks quantity movement through an unresolved conflicting lot', () async {
      final a = _lot('a', expiry: '2027-01');
      final b = _lot('b', expiry: '2027-02');
      final storage = MemoryInventoryStorage(_snapshot(a, b));

      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Receive stock',
            upserts: [a.patch({'quantity': 15})],
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('conflicting saved batch facts'),
          ),
        ),
      );

      expect((await storage.load()).revision, 0);
      expect((await storage.load()).records['a']!.quantity, 10);
    });

    test('blocks a new contradictory duplicate before it reaches storage', () async {
      final a = _lot('a', expiry: '2027-01');
      final storage = MemoryInventoryStorage(
        InventorySnapshot(records: {a.id: a}),
      );
      final duplicate = _lot('b', expiry: '2027-02');

      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Add duplicate',
            upserts: [duplicate],
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('two contradictory versions'),
          ),
        ),
      );
      expect((await storage.load()).records.keys, {'a'});
    });

    test('allows an edit that completely resolves the physical-lot conflict', () async {
      final a = _lot('a', expiry: '2027-01');
      final b = _lot('b', expiry: '2027-02');
      final storage = MemoryInventoryStorage(_snapshot(a, b));

      final result = await storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Correct expiry',
          upserts: [b.patch({'expiry': '2027-01'})],
        ),
      );

      expect(result.revision, 1);
      expect(result.records['b']!.expiry, DateTime.utc(2027, 1, 31));
    });

    test('allows archive repair and unrelated metadata edits', () async {
      final a = _lot('a', expiry: '2027-01');
      final b = _lot('b', expiry: '2027-02');

      final metadataStorage = MemoryInventoryStorage(_snapshot(a, b));
      final metadataResult = await metadataStorage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Update note',
          upserts: [a.patch({'notes': 'Verified shelf label'})],
        ),
      );
      expect(metadataResult.records['a']!.notes, 'Verified shelf label');

      final archiveStorage = MemoryInventoryStorage(_snapshot(a, b));
      final archiveResult = await archiveStorage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Remove duplicate',
          upserts: [
            archiveMedicine(
              b,
              reason: 'Duplicate physical row',
              at: today,
            ),
          ],
        ),
      );
      expect(archiveResult.records['b']!.archived, isTrue);
    });
  });
}
