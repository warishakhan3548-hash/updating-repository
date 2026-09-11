import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/dispensing_plan.dart';
import 'package:aaris_pharmacy/domain/inventory.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock({
  required String id,
  required DateTime? expiry,
  required int? quantity,
  DateTime? mfg,
  String batch = '',
  String name = 'Dolo',
  String salt = 'Paracetamol',
  String strength = '650 mg',
  bool sold = false,
  bool archived = false,
}) => Medicine(
  id: id,
  name: name,
  salt: salt,
  strength: strength,
  form: 'Tablet',
  mfg: mfg,
  expiry: expiry,
  quantity: sold ? 0 : quantity,
  batchNumber: batch,
  sold: sold,
  archived: archived,
);

void main() {
  final today = DateTime(2026, 9, 9, 12);

  test('FEFO plan spans physical batches in expiry order', () {
    final early = stock(
      id: 'early',
      expiry: DateTime.utc(2026, 10, 1),
      quantity: 3,
      batch: 'A',
    );
    final later = stock(
      id: 'later',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 5,
      batch: 'B',
    );
    final plan = planFefoDispensing(
      records: [later, early],
      requested: later,
      quantity: 6,
      date: today,
    );

    expect(plan.complete, isTrue);
    expect(plan.allocations.map((item) => item.stockId), ['early', 'later']);
    expect(plan.allocations.map((item) => item.quantity), [3, 3]);
    expect(plan.allocations.first.emptiesStock, isTrue);
    expect(plan.allocations.last.emptiesStock, isFalse);
  });

  test('unknown earlier FEFO quantity blocks automatic allocation', () {
    final unknown = stock(
      id: 'unknown',
      expiry: DateTime.utc(2026, 10, 1),
      quantity: null,
      batch: 'A',
    );
    final known = stock(
      id: 'known',
      expiry: DateTime.utc(2026, 11, 1),
      quantity: 10,
      batch: 'B',
    );
    final plan = planFefoDispensing(
      records: [known, unknown],
      requested: known,
      quantity: 5,
      date: today,
    );

    expect(plan.complete, isFalse);
    expect(plan.blockedByUnknownQuantity, isTrue);
    expect(plan.plannedQuantity, 0);
    expect(plan.unknownQuantityStockIds, ['unknown']);
  });

  test('future manufacturing stock is excluded from FEFO choices', () {
    final future = stock(
      id: 'future',
      mfg: DateTime.utc(2026, 10, 1),
      expiry: DateTime.utc(2026, 11, 1),
      quantity: 4,
      batch: 'F',
    );
    final valid = stock(
      id: 'valid',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 5,
      batch: 'V',
    );

    expect(isDispensableOn(future, today), isFalse);
    final plan = planFefoDispensing(
      records: [future, valid],
      requested: valid,
      quantity: 4,
      date: today,
    );
    expect(plan.complete, isTrue);
    expect(plan.allocations.map((item) => item.stockId), ['valid']);
  });

  test('unknown expiry is visible and requires physical verification', () {
    final dated = stock(
      id: 'dated',
      expiry: DateTime.utc(2026, 10, 1),
      quantity: 2,
    );
    final unknownExpiry = stock(id: 'unknown-exp', expiry: null, quantity: 5);
    final plan = planFefoDispensing(
      records: [unknownExpiry, dated],
      requested: dated,
      quantity: 4,
      date: today,
    );
    expect(plan.complete, isFalse);
    expect(plan.blockedByUnknownExpiry, isTrue);
    expect(plan.requiresExpiryVerification, isTrue);
    expect(plan.plannedQuantity, 0);
    expect(plan.allocations, isEmpty);
    expect(plan.unknownExpiryStockIds, ['unknown-exp']);
  });

  test('controller applies reviewed multi-batch sale atomically and undo restores all', () async {
    final early = stock(
      id: 'early',
      expiry: DateTime.utc(2026, 10, 1),
      quantity: 3,
      batch: 'A',
    );
    final later = stock(
      id: 'later',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 5,
      batch: 'B',
    );
    final storage = MemoryInventoryStorage(
      InventorySnapshot(records: {'early': early, 'later': later}),
    );
    final controller = PharmacyController(
      storage,
      clock: () => today,
      backgroundSearch: false,
    );
    await controller.initialize();

    final review = controller.reviewFefoSale('later', quantity: 6);
    expect(review.baseRevision, 0);
    expect(review.plan.complete, isTrue);
    await controller.applyFefoSale(review);

    expect(controller.snapshot.revision, 1);
    expect(controller.snapshot.records['early']!.quantity, 0);
    expect(controller.snapshot.records['early']!.sold, isTrue);
    expect(controller.snapshot.records['later']!.quantity, 2);
    expect(controller.snapshot.records['later']!.sold, isFalse);
    expect(controller.sales.map((sale) => sale.quantity).toList()..sort(), [
      3,
      3,
    ]);
    expect(controller.canUndo, isTrue);

    await controller.undo();
    expect(controller.snapshot.records['early']!.quantity, 3);
    expect(controller.snapshot.records['early']!.sold, isFalse);
    expect(controller.snapshot.records['later']!.quantity, 5);
    expect(controller.sales, isEmpty);
    controller.dispose();
  });

  test('FEFO review rebases across unrelated inventory traffic', () async {
    final item = stock(
      id: 'one',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 10,
    );
    final storage = MemoryInventoryStorage(
      InventorySnapshot(records: {'one': item}),
    );
    final controller = PharmacyController(
      storage,
      clock: () => today,
      backgroundSearch: false,
    );
    await controller.initialize();

    final review = controller.reviewFefoSale('one', quantity: 2);
    await controller.save(
      stock(
        id: 'other',
        name: 'Crocin',
        strength: '500 mg',
        expiry: DateTime.utc(2027, 1, 1),
        quantity: 7,
      ),
      expectedRevision: controller.snapshot.revision,
    );

    await controller.applyFefoSale(review);
    expect(controller.snapshot.records['one']!.quantity, 8);
    expect(controller.snapshot.records['other']!.quantity, 7);
    expect(controller.sales, hasLength(1));
    controller.dispose();
  });

  test(
    'FEFO review fails if a new earlier same-product batch appears',
    () async {
      final item = stock(
        id: 'one',
        expiry: DateTime.utc(2026, 12, 1),
        quantity: 10,
      );
      final storage = MemoryInventoryStorage(
        InventorySnapshot(records: {'one': item}),
      );
      final controller = PharmacyController(
        storage,
        clock: () => today,
        backgroundSearch: false,
      );
      await controller.initialize();

      final review = controller.reviewFefoSale('one', quantity: 2);
      await controller.save(
        stock(
          id: 'earlier',
          expiry: DateTime.utc(2026, 10, 1),
          quantity: 5,
          batch: 'EARLY',
        ),
        expectedRevision: controller.snapshot.revision,
      );

      await expectLater(controller.applyFefoSale(review), throwsStateError);
      expect(controller.snapshot.records['one']!.quantity, 10);
      expect(controller.snapshot.records['earlier']!.quantity, 5);
      expect(controller.sales, isEmpty);
      controller.dispose();
    },
  );

  test('stale FEFO review cannot mutate a newer inventory revision', () async {
    final item = stock(
      id: 'one',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 10,
    );
    final storage = MemoryInventoryStorage(
      InventorySnapshot(records: {'one': item}),
    );
    final controller = PharmacyController(
      storage,
      clock: () => today,
      backgroundSearch: false,
    );
    await controller.initialize();
    final review = controller.reviewFefoSale('one', quantity: 2);
    await controller.save(
      item.patch({'notes': 'counted'}),
      expectedRevision: controller.snapshot.revision,
    );

    await expectLater(
      controller.applyFefoSale(review),
      throwsA(isA<StateError>()),
    );
    expect(controller.snapshot.records['one']!.quantity, 10);
    expect(controller.sales, isEmpty);
    controller.dispose();
  });
}
