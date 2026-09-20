import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/backup.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(String id, {int quantity = 10}) =>
    Medicine.fromJson(<String, dynamic>{
      'id': id,
      'name': 'Medicine $id',
      'strength': '500 mg',
      'form': 'Tablet',
      'expiry': '2027-12-31',
      'quantity': quantity,
      'unitPricePaise': 200,
      'revision': 1,
    });

void main() {
  test('inventory snapshot deeply freezes activity and Undo payloads', () {
    final sourceStock = <String, dynamic>{
      'id': 'stock-a',
      'name': 'Dolo',
      'form': 'Tablet',
      'quantity': 10,
      'revision': 1,
    };
    final sourceBefore = <String, dynamic>{'stock-a': sourceStock};
    final sourceEvent = <String, dynamic>{
      'id': 'event-a',
      'revision': 1,
      'label': 'Edited Dolo',
      'time': '2026-09-20T03:00:00.000Z',
      'undoable': true,
      'undone': false,
      'before': sourceBefore,
      'supplierBefore': <String, dynamic>{},
      'salesBefore': <String, dynamic>{},
      'settingsBefore': <String, dynamic>{'shortDays': 8, 'months': 2},
      'soldValue': 0,
      'unknownSold': 0,
    };

    final snapshot = InventorySnapshot(
      events: <Map<String, dynamic>>[sourceEvent],
    );

    sourceEvent['label'] = 'Tampered outside snapshot';
    sourceBefore['stock-a'] = null;
    sourceStock['name'] = 'Tampered medicine';

    expect(snapshot.events.single['label'], 'Edited Dolo');
    final before = snapshot.events.single['before'] as Map;
    final stock = before['stock-a'] as Map;
    expect(stock['name'], 'Dolo');

    expect(
      () => snapshot.events.single['label'] = 'Mutated',
      throwsUnsupportedError,
    );
    expect(() => before['stock-a'] = null, throwsUnsupportedError);
    expect(() => stock['name'] = 'Mutated', throwsUnsupportedError);
  });

  test('snapshot transitions reuse untouched frozen activity rows', () {
    final before = InventorySnapshot(
      events: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'event-a',
          'revision': 1,
          'label': 'Previous change',
          'time': '2026-09-20T03:00:00.000Z',
          'undoable': false,
          'undone': false,
          'before': <String, dynamic>{},
          'supplierBefore': <String, dynamic>{},
          'salesBefore': <String, dynamic>{},
          'settingsBefore': <String, dynamic>{'shortDays': 8, 'months': 2},
          'soldValue': 0,
          'unknownSold': 0,
        },
      ],
    );
    final mutation = InventoryMutation(
      expectedRevision: before.revision,
      label: 'Warning setting',
      upserts: const <Medicine>[],
      settings: const WarningSettings(shortDays: 5, months: 2),
      operationTime: DateTime.utc(2026, 9, 20, 4),
    );

    final after = nextSnapshot(before, mutation, makeEvent(before, mutation));

    expect(after.events, hasLength(2));
    expect(identical(after.events[1], before.events[0]), isTrue);
    expect(
      () => after.events.first['label'] = 'Mutated',
      throwsUnsupportedError,
    );
  });

  test('backup aggregate restore is not recorded as a new SOLD transition', () {
    final active = _stock('stock-a');
    final sold = Medicine.fromJson(<String, dynamic>{
      ...active.toJson(),
      'sold': true,
      'quantity': 0,
      'soldAt': '2026-09-19T10:00:00.000Z',
      'soldQuantity': 10,
      'soldUnitPricePaise': 200,
      'revision': 2,
    });
    final before = InventorySnapshot(
      records: <String, Medicine>{active.id: active},
    );
    final mutation = InventoryMutation(
      expectedRevision: before.revision,
      label: 'Restored backup',
      upserts: <Medicine>[sold],
      soldValueOverride: 2000,
      unknownSoldOverride: 0,
      operationTime: DateTime.utc(2026, 9, 20, 4),
    );

    final event = makeEvent(before, mutation);

    expect(event['soldValue'], 0);
    expect(event['unknownSold'], 0);
  });

  test('restore yields before commit and rejects a newly stale review', () async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => DateTime(2026, 9, 20, 9, 30),
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    final records = <String, Medicine>{
      for (var index = 0; index < 600; index++)
        'incoming-$index': _stock('incoming-$index'),
    };
    final backup = PharmacyBackup(
      createdAt: DateTime(2026, 9, 20, 9),
      sourceRevision: 12,
      settings: const WarningSettings(),
      records: records,
      sales: const {},
      soldValue: 0,
      unknownSold: 0,
    );
    final review = BackupReview(
      backup: backup,
      currentRevision: controller.snapshot.revision,
    );

    final restoring = controller.restoreBackup(review);
    await controller.save(
      _stock('concurrent-local'),
      expectedRevision: controller.snapshot.revision,
    );

    await expectLater(restoring, throwsStateError);
    expect(controller.snapshot.records, contains('concurrent-local'));
    expect(controller.snapshot.records, isNot(contains('incoming-0')));
  });
}
