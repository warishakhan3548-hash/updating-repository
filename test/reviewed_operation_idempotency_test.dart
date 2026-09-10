import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/state/pharmacy_controller.dart';
import 'domain_contract.dart';

void main() {
  late PharmacyController controller;

  setUp(() async {
    controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => contractToday,
      backgroundSearch: false,
    );
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
  });

  test(
    'concurrent replay of one reviewed receipt increments stock once',
    () async {
      await controller.save(stock('a', quantity: 10), expectedRevision: 0);
      final review = controller.reviewStockAdjustment(
        'a',
        kind: StockAdjustmentKind.receive,
        quantity: 5,
      );

      await Future.wait([
        controller.applyStockAdjustment(review),
        controller.applyStockAdjustment(review),
      ]);

      expect(controller.snapshot.records['a']!.quantity, 15);
      expect(controller.snapshot.revision, 2);
      expect(controller.snapshot.receipts, contains(review.requestId));
      expect(
        controller.snapshot.events.where(
          (event) => (event['label'] as String).startsWith('Received stock'),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'a committed review remains exactly once after unrelated later writes',
    () async {
      await controller.save(stock('a', quantity: 10), expectedRevision: 0);
      final first = controller.reviewStockAdjustment(
        'a',
        kind: StockAdjustmentKind.receive,
        quantity: 5,
      );
      await controller.applyStockAdjustment(first);
      await controller.save(stock('b', quantity: 4), expectedRevision: 2);
      final revisionBeforeReplay = controller.snapshot.revision;

      await controller.applyStockAdjustment(first);

      expect(controller.snapshot.revision, revisionBeforeReplay);
      expect(controller.snapshot.records['a']!.quantity, 15);

      final distinct = controller.reviewStockAdjustment(
        'a',
        kind: StockAdjustmentKind.receive,
        quantity: 2,
      );
      expect(distinct.requestId, isNot(first.requestId));
      await controller.applyStockAdjustment(distinct);
      expect(controller.snapshot.records['a']!.quantity, 17);
      expect(controller.snapshot.revision, revisionBeforeReplay + 1);
    },
  );

  test('concurrent replay of one reviewed FEFO sale creates one sale ledger effect', () async {
    await controller.save(
      stock('a', quantity: 10, expiry: '2026-10-01'),
      expectedRevision: 0,
    );
    final review = controller.reviewFefoSale('a', quantity: 3);

    await Future.wait([
      controller.applyFefoSale(review),
      controller.applyFefoSale(review),
    ]);

    expect(controller.snapshot.records['a']!.quantity, 7);
    expect(controller.sales, hasLength(1));
    expect(controller.sales.single.quantity, 3);
    expect(controller.snapshot.revision, 2);
    expect(controller.snapshot.receipts, contains(review.requestId));
  });

  test('receipt replay stays blocked after Undo while a fresh review remains possible', () async {
    await controller.save(stock('a', quantity: 10), expectedRevision: 0);
    final review = controller.reviewStockAdjustment(
      'a',
      kind: StockAdjustmentKind.receive,
      quantity: 5,
    );
    await controller.applyStockAdjustment(review);
    await controller.undo();
    expect(controller.snapshot.records['a']!.quantity, 10);
    final afterUndoRevision = controller.snapshot.revision;

    await controller.applyStockAdjustment(review);

    expect(controller.snapshot.records['a']!.quantity, 10);
    expect(controller.snapshot.revision, afterUndoRevision);
    expect(controller.snapshot.receipts, contains(review.requestId));

    final fresh = controller.reviewStockAdjustment(
      'a',
      kind: StockAdjustmentKind.receive,
      quantity: 5,
    );
    await controller.applyStockAdjustment(fresh);
    expect(controller.snapshot.records['a']!.quantity, 15);
  });
}
