import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/automation_guard.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _lot(
  String id, {
  String name = 'Dolo',
  String strength = '650mg',
  String expiry = '2027-01',
  String mfg = '',
  String barcode = '8901234567890',
  String batch = 'LOT-17',
  int quantity = 10,
  String notes = '',
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'form': 'Tablet',
  'mfg': mfg,
  'expiry': expiry,
  'barcode': barcode,
  'batchNumber': batch,
  'quantity': quantity,
  'notes': notes,
});

InventorySnapshot _snapshot(Medicine a, Medicine b) =>
    InventorySnapshot(records: {a.id: a, b.id: b});

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

    test(
      'blocks quantity movement through an unresolved conflicting lot',
      () async {
        final a = _lot('a', expiry: '2027-01');
        final b = _lot('b', expiry: '2027-02');
        final storage = MemoryInventoryStorage(_snapshot(a, b));

        await expectLater(
          storage.commit(
            InventoryMutation(
              expectedRevision: 0,
              label: 'Receive stock',
              upserts: [
                a.patch({'quantity': 15}),
              ],
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
      },
    );

    test(
      'blocks a new contradictory duplicate before it reaches storage',
      () async {
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
        expect((await storage.load()).records.keys.toSet(), {'a'});
      },
    );

    test(
      'allows an edit that completely resolves the physical-lot conflict',
      () async {
        final a = _lot('a', expiry: '2027-01');
        final b = _lot('b', expiry: '2027-02');
        final storage = MemoryInventoryStorage(_snapshot(a, b));

        final result = await storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Correct expiry',
            upserts: [
              b.patch({'expiry': '2027-01'}),
            ],
          ),
        );

        expect(result.revision, 1);
        expect(result.records['b']!.expiry, DateTime.utc(2027, 1, 31));
      },
    );

    test('allows archive repair and unrelated metadata edits', () async {
      final a = _lot('a', expiry: '2027-01');
      final b = _lot('b', expiry: '2027-02');

      final metadataStorage = MemoryInventoryStorage(_snapshot(a, b));
      final metadataResult = await metadataStorage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Update note',
          upserts: [
            a.patch({'notes': 'Verified shelf label'}),
          ],
        ),
      );
      expect(metadataResult.records['a']!.notes, 'Verified shelf label');

      final archiveStorage = MemoryInventoryStorage(_snapshot(a, b));
      final archiveResult = await archiveStorage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Remove duplicate',
          upserts: [
            archiveMedicine(b, reason: 'Duplicate physical row', at: today),
          ],
        ),
      );
      expect(archiveResult.records['b']!.archived, isTrue);
    });
  });

  group('autonomous scanner identity firewall', () {
    test(
      'blocks one barcode from being assigned to different medicines',
      () async {
        final a = _lot(
          'a',
          name: 'Dolo',
          strength: '650mg',
          barcode: '111222333',
        );
        final b = _lot(
          'b',
          name: 'Crocin',
          strength: '500mg',
          barcode: '111222333',
          batch: 'OTHER-2',
        );
        final storage = MemoryInventoryStorage(
          InventorySnapshot(records: {a.id: a}),
        );

        await expectLater(
          storage.commit(
            InventoryMutation(
              expectedRevision: 0,
              label: 'Add scanned stock',
              upserts: [b],
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('barcode 111222333'),
                contains('different medicine identities'),
              ),
            ),
          ),
        );
        expect((await storage.load()).records.keys.toSet(), {'a'});
      },
    );

    test('pauses stock movement on an already-conflicting barcode', () async {
      final a = _lot('a', name: 'Dolo', strength: '650mg', barcode: '777');
      final b = _lot(
        'b',
        name: 'Crocin',
        strength: '500mg',
        barcode: '777',
        batch: 'OTHER-2',
      );
      final storage = MemoryInventoryStorage(_snapshot(a, b));

      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Receive stock',
            upserts: [
              a.patch({'quantity': 11}),
            ],
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('barcode identity conflict'),
          ),
        ),
      );
      expect((await storage.load()).records['a']!.quantity, 10);
    });

    test(
      'allows the pharmacist to resolve a barcode conflict atomically',
      () async {
        final a = _lot('a', name: 'Dolo', strength: '650mg', barcode: '777');
        final b = _lot(
          'b',
          name: 'Crocin',
          strength: '500mg',
          barcode: '777',
          batch: 'OTHER-2',
        );
        final storage = MemoryInventoryStorage(_snapshot(a, b));

        final result = await storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Correct barcode',
            upserts: [
              b.patch({'barcode': '888'}),
            ],
          ),
        );

        expect(result.revision, 1);
        expect(result.records['b']!.barcode, '888');
      },
    );
  });

  group('impossible manufacturing-date firewall', () {
    test(
      'blocks newly introduced active stock manufactured in the future',
      () async {
        final future = _lot(
          'future',
          mfg: '2099-01',
          expiry: '2100-01',
          barcode: 'future-1',
        );
        final storage = MemoryInventoryStorage();

        await expectLater(
          storage.commit(
            InventoryMutation(
              expectedRevision: 0,
              label: 'Add future stock',
              upserts: [future],
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('manufacturing date in the future'),
            ),
          ),
        );
        expect((await storage.load()).records, isEmpty);
      },
    );

    test(
      'allows harmless review but blocks stock movement until MFG is fixed',
      () async {
        final future = _lot(
          'future',
          mfg: '2099-01',
          expiry: '2100-01',
          barcode: 'future-1',
        );

        final noteStorage = MemoryInventoryStorage(
          InventorySnapshot(records: {future.id: future}),
        );
        final reviewed = await noteStorage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Record verification note',
            upserts: [
              future.patch({'notes': 'Pack date needs recheck'}),
            ],
          ),
        );
        expect(reviewed.records['future']!.notes, 'Pack date needs recheck');

        final movementStorage = MemoryInventoryStorage(
          InventorySnapshot(records: {future.id: future}),
        );
        await expectLater(
          movementStorage.commit(
            InventoryMutation(
              expectedRevision: 0,
              label: 'Receive stock',
              upserts: [
                future.patch({'quantity': 12}),
              ],
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('manufacturing date in the future'),
            ),
          ),
        );

        final repairStorage = MemoryInventoryStorage(
          InventorySnapshot(records: {future.id: future}),
        );
        final repaired = await repairStorage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Correct MFG',
            upserts: [
              future.patch({'mfg': '2026-01'}),
            ],
          ),
        );
        expect(repaired.revision, 1);
        expect(repaired.records['future']!.mfg, DateTime.utc(2026, 1, 1));
      },
    );
  });
}
