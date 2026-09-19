import 'dart:io';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _futureDatedStock(String id) => Medicine.fromJson({
  'id': id,
  'name': 'Clock Test Medicine',
  'strength': '10mg',
  'form': 'Tablet',
  'mfg': '2027-01-01',
  'expiry': '2028-01',
  'quantity': 10,
  'barcode': 'clock-$id',
  'batchNumber': 'CLOCK-$id',
});

class _ControllableClock {
  _ControllableClock(this.current);

  DateTime current;
  final List<DateTime> _queued = <DateTime>[];

  DateTime call() => _queued.isEmpty ? current : _queued.removeAt(0);

  void queue(Iterable<DateTime> values) {
    _queued
      ..clear()
      ..addAll(values);
  }
}

void main() {
  group('authoritative inventory business clock', () {
    test(
      'persistence guards use the reviewed operation day, not wall time',
      () async {
        final storage = MemoryInventoryStorage();
        final record = _futureDatedStock('direct');
        final operationTime = DateTime.utc(2027, 1, 1, 9, 30);

        final result = await storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Add clock-controlled stock',
            upserts: [record],
            operationTime: operationTime,
          ),
        );

        expect(result.revision, 1);
        expect(result.records['direct']?.mfg, DateTime.utc(2027, 1, 1));
        expect(
          result.events.first['time'],
          operationTime.toUtc().toIso8601String(),
        );
        expect(result.events.first['businessDay'], '2027-01-01');
      },
    );

    test(
      'the same future MFG is blocked on the preceding business day',
      () async {
        final storage = MemoryInventoryStorage();
        final record = _futureDatedStock('blocked');

        await expectLater(
          storage.commit(
            InventoryMutation(
              expectedRevision: 0,
              label: 'Add too-early stock',
              upserts: [record],
              operationTime: DateTime.utc(2026, 12, 31, 23, 59, 59),
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

        expect((await storage.load()).revision, 0);
        expect((await storage.load()).records, isEmpty);
      },
    );

    test(
      'controller clock is propagated to the persistence boundary',
      () async {
        final operationTime = DateTime.utc(2027, 1, 1, 11, 45);
        final controller = PharmacyController(
          MemoryInventoryStorage(),
          clock: () => operationTime,
          backgroundSearch: false,
        );
        await controller.initialize();
        addTearDown(controller.dispose);

        final record = _futureDatedStock('controller');
        await controller.save(
          record,
          expectedRevision: controller.snapshot.revision,
        );

        expect(
          controller.snapshot.records['controller']?.mfg,
          DateTime.utc(2027, 1, 1),
        );
        expect(
          controller.snapshot.events.first['time'],
          operationTime.toIso8601String(),
        );
        expect(controller.snapshot.events.first['businessDay'], '2027-01-01');
      },
    );

    test(
      'manual SOLD lifecycle time is owned by the serialized commit',
      () async {
        final operationTime = DateTime.utc(2026, 9, 20, 23, 59, 59);
        final staleCallerTime = DateTime.utc(2026, 9, 19, 12);
        final stock = Medicine.fromJson(<String, dynamic>{
          'id': 'sold-clock',
          'name': 'Sold Clock Medicine',
          'strength': '10mg',
          'form': 'Tablet',
          'expiry': '2027-01-01',
          'quantity': 3,
        });
        final controller = PharmacyController(
          MemoryInventoryStorage(
            InventorySnapshot(
              records: <String, Medicine>{stock.id: stock},
            ),
          ),
          clock: () => operationTime,
          backgroundSearch: false,
        );
        await controller.initialize();
        addTearDown(controller.dispose);

        final reviewed = controller.snapshot.records[stock.id]!;
        await controller.save(
          reviewed.patch(<String, dynamic>{
            'sold': true,
            'quantity': 0,
            'soldAt': staleCallerTime.toIso8601String(),
            'soldQuantity': reviewed.quantity,
            'soldUnitPricePaise': reviewed.unitPricePaise,
          }),
          expectedRevision: controller.snapshot.revision,
        );

        final saved = controller.snapshot.records[stock.id]!;
        expect(saved.soldAt, operationTime.toIso8601String());
        expect(controller.sales.single.occurredAt, operationTime);
        expect(
          controller.snapshot.events.first['time'],
          operationTime.toIso8601String(),
        );
        expect(controller.snapshot.events.first['businessDay'], '2026-09-20');
      },
    );

    test(
      'receive-stock confirmation keeps one business instant across midnight',
      () async {
        final beforeMidnight = DateTime(2026, 9, 20, 23, 59, 59);
        final afterMidnight = DateTime(2026, 9, 21, 0, 0, 1);
        final stock = Medicine.fromJson(<String, dynamic>{
          'id': 'midnight-receive',
          'name': 'Midnight Receive',
          'strength': '10mg',
          'form': 'Tablet',
          'expiry': '2026-09-20',
          'quantity': 10,
        });
        final clock = _ControllableClock(beforeMidnight);
        final controller = PharmacyController(
          MemoryInventoryStorage(
            InventorySnapshot(
              records: <String, Medicine>{stock.id: stock},
            ),
          ),
          clock: clock.call,
          backgroundSearch: false,
        );
        await controller.initialize();
        addTearDown(controller.dispose);

        final review = controller.reviewStockAdjustment(
          stock.id,
          kind: StockAdjustmentKind.receive,
          quantity: 2,
        );

        clock
          ..current = afterMidnight
          ..queue(<DateTime>[beforeMidnight, afterMidnight]);

        await controller.applyStockAdjustment(review);

        expect(controller.snapshot.records[stock.id]?.quantity, 12);
        expect(
          controller.snapshot.events.first['time'],
          beforeMidnight.toUtc().toIso8601String(),
        );
        expect(
          controller.snapshot.events.first['businessDay'],
          '2026-09-20',
        );
      },
    );

    test('local business day survives UTC audit normalization', () async {
      final storage = MemoryInventoryStorage();
      final operationTime = DateTime(2027, 1, 1, 0, 30);
      final result = await storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Local-midnight stock intake',
          upserts: [_futureDatedStock('local-midnight')],
          operationTime: operationTime,
        ),
      );

      expect(result.events.first['businessDay'], '2027-01-01');
      expect(result.records['local-midnight']?.mfg, DateTime.utc(2027, 1, 1));
      expect(
        result.events.first['time'],
        operationTime.toUtc().toIso8601String(),
      );

      if (Platform.environment['AARIS_REQUIRE_NON_UTC_CLOCK_TEST'] == '1') {
        expect(
          operationTime.timeZoneOffset,
          const Duration(hours: 5, minutes: 30),
        );
        expect(
          DateTime.parse(result.events.first['time'] as String).day,
          31,
          reason: 'The UTC audit instant must be allowed to fall on the previous UTC day while businessDay stays Jan 1.',
        );
      }
    });

    test('operation time validation fails closed before persistence', () async {
      final storage = MemoryInventoryStorage();
      final record = _futureDatedStock('invalid-time');

      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Invalid clock',
            upserts: [record],
            operationTime: DateTime.utc(2300, 1, 1),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect((await storage.load()).revision, 0);
    });
  });
}
