import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(
  String id, {
  int? quantity = 10,
  bool sold = false,
  String? expiry = '2027-12',
}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'form': 'Tablet',
  'quantity': sold ? 0 : quantity,
  'expiry': expiry,
  'sold': sold,
  'soldAt': sold ? '2026-09-09T10:00:00.000' : null,
  'soldQuantity': sold ? quantity : null,
  'revision': 1,
});

Future<PharmacyController> controllerWithClock() async {
  final controller = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  group('Aaris Brain reviewed stock operations', () {
    test('parses exact receive and quantity-correction commands', () {
      final receive = parseAppBrainIntent('Dolo 650 stock add 12 units');
      expect(receive.action, AppBrainAction.receiveStock);
      expect(receive.query, 'Dolo 650');
      expect(receive.quantity, 12);
      expect(receive.confidence, greaterThanOrEqualTo(.99));

      final correction = parseAppBrainIntent('Dolo 650 quantity 20 set karo');
      expect(correction.action, AppBrainAction.setQuantity);
      expect(correction.query, 'Dolo 650');
      expect(correction.quantity, 20);
      expect(correction.destructive, isTrue);

      final hindi = parseAppBrainIntent('Dolo 650 स्टॉक बढ़ाओ ५ यूनिट');
      expect(hindi.action, AppBrainAction.receiveStock);
      expect(hindi.query, 'Dolo 650');
      expect(hindi.quantity, 5);
    });

    test('stock command can safely reuse the last exact context reference', () {
      final intent = parseAppBrainIntent('isko stock add 7 units');
      expect(intent.action, AppBrainAction.receiveStock);
      expect(intent.query, 'isko');
      expect(intent.quantity, 7);
      expect(isAppBrainContextReference(intent.query), isTrue);

      final english = parseAppBrainIntent('this quantity 9 set karo');
      expect(english.action, AppBrainAction.setQuantity);
      expect(english.query, 'this');
      expect(isAppBrainContextReference(english.query), isTrue);
    });

    test(
      'complete targetless operations can bind only at execution context',
      () {
        final receive = parseAppBrainIntent('stock add 7 units');
        expect(receive.action, AppBrainAction.receiveStock);
        expect(receive.query, isEmpty);
        expect(receive.canUseImplicitExactContext, isTrue);

        final relocate = parseAppBrainIntent('location Rack C set karo');
        expect(relocate.action, AppBrainAction.relocateMedicine);
        expect(relocate.query, isEmpty);
        expect(relocate.locationPatch?.location, 'Rack C');
        expect(relocate.canUseImplicitExactContext, isTrue);
      },
    );

    test('medicine strength is never consumed as a stock command quantity', () {
      final lookup = parseAppBrainIntent('Dolo 650');
      expect(lookup.action, AppBrainAction.search);
      expect(lookup.query, 'Dolo 650');

      final receive = parseAppBrainIntent('Dolo 650 restock 4 units');
      expect(receive.query, 'Dolo 650');
      expect(receive.quantity, 4);
    });
  });

  group('transactional stock adjustment safety', () {
    test('received stock is reviewed, atomic and undoable', () async {
      final controller = await controllerWithClock();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);

      final review = controller.reviewStockAdjustment(
        'a',
        kind: StockAdjustmentKind.receive,
        quantity: 5,
      );
      expect(review.beforeQuantity, 10);
      expect(review.afterQuantity, 15);
      await controller.applyStockAdjustment(review);

      expect(controller.snapshot.records['a']!.quantity, 15);
      expect(controller.sales, isEmpty);
      expect(
        controller.snapshot.events.first['label'],
        contains('Received stock'),
      );
      await controller.undo();
      expect(controller.snapshot.records['a']!.quantity, 10);
    });

    test(
      'receiving stock reopens SOLD explicitly without deleting sale history',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a', quantity: 6), expectedRevision: 0);
        await controller.recordSale(
          'a',
          quantity: 6,
          markSoldOut: true,
          totalAmountPaise: 6000,
        );
        expect(controller.snapshot.records['a']!.sold, isTrue);
        expect(controller.sales, hasLength(1));

        final review = controller.reviewStockAdjustment(
          'a',
          kind: StockAdjustmentKind.receive,
          quantity: 8,
        );
        expect(review.wasSold, isTrue);
        await controller.applyStockAdjustment(review);

        final restored = controller.snapshot.records['a']!;
        expect(restored.sold, isFalse);
        expect(restored.quantity, 8);
        expect(controller.sales, hasLength(1));
      },
    );

    test(
      'unknown baseline and expired physical entry block stock receiving',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(
          stock('unknown', quantity: null),
          expectedRevision: 0,
        );
        await controller.save(
          stock('expired', quantity: 3, expiry: '2026-09-09'),
          expectedRevision: 1,
        );

        expect(
          () => controller.reviewStockAdjustment(
            'unknown',
            kind: StockAdjustmentKind.receive,
            quantity: 2,
          ),
          throwsFormatException,
        );
        expect(
          () => controller.reviewStockAdjustment(
            'expired',
            kind: StockAdjustmentKind.receive,
            quantity: 2,
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'exact quantity correction never invents a sale or silent SOLD state',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a', quantity: 10), expectedRevision: 0);

        final review = controller.reviewStockAdjustment(
          'a',
          kind: StockAdjustmentKind.setExact,
          quantity: 0,
        );
        await controller.applyStockAdjustment(review);

        final corrected = controller.snapshot.records['a']!;
        expect(corrected.quantity, 0);
        expect(corrected.sold, isFalse);
        expect(controller.sales, isEmpty);
      },
    );

    test(
      'review survives unrelated writes but rejects target changes',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a'), expectedRevision: 0);
        final review = controller.reviewStockAdjustment(
          'a',
          kind: StockAdjustmentKind.receive,
          quantity: 2,
        );
        await controller.save(stock('b'), expectedRevision: 1);

        await controller.applyStockAdjustment(review);
        expect(controller.snapshot.records['a']!.quantity, 12);
        expect(controller.snapshot.records['b']!.quantity, 10);

        final stale = controller.reviewStockAdjustment(
          'a',
          kind: StockAdjustmentKind.receive,
          quantity: 2,
        );
        final live = controller.snapshot.records['a']!;
        await controller.save(
          live.patch({'notes': 'physical count rechecked'}),
          expectedRevision: controller.snapshot.revision,
        );
        await expectLater(
          controller.applyStockAdjustment(stale),
          throwsStateError,
        );
        expect(controller.snapshot.records['a']!.quantity, 12);
      },
    );

    test(
      'reviewed removal survives unrelated writes but rejects target edits',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a'), expectedRevision: 0);
        final review = controller.reviewArchive('a', 'Damaged');
        await controller.save(stock('b'), expectedRevision: 1);

        await controller.applyArchive(review);
        expect(controller.snapshot.records['a']!.archived, isTrue);
        expect(controller.snapshot.records['a']!.archiveReason, 'Damaged');
        expect(controller.snapshot.records['b']!.archived, isFalse);

        await controller.undo();
        final stale = controller.reviewArchive('a', 'Correction');
        final live = controller.snapshot.records['a']!;
        await controller.save(
          live.patch({'notes': 'changed after confirmation opened'}),
          expectedRevision: controller.snapshot.revision,
        );
        await expectLater(controller.applyArchive(stale), throwsStateError);
        expect(controller.snapshot.records['a']!.archived, isFalse);
      },
    );

    test(
      'reviewed SOLD survives unrelated writes but rejects target edits',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a'), expectedRevision: 0);
        final review = controller.reviewMarkSold('a');
        await controller.save(stock('b'), expectedRevision: 1);

        await controller.applyMarkSold(review);
        final sold = controller.snapshot.records['a']!;
        expect(sold.sold, isTrue);
        expect(sold.quantity, 0);
        expect(controller.sales, isEmpty);

        await controller.undo();
        final stale = controller.reviewMarkSold('a');
        final live = controller.snapshot.records['a']!;
        await controller.save(
          live.patch({'notes': 'count verified'}),
          expectedRevision: controller.snapshot.revision,
        );
        await expectLater(controller.applyMarkSold(stale), throwsStateError);
        expect(controller.snapshot.records['a']!.sold, isFalse);
      },
    );

    test(
      'unknown stock cannot be marked fully sold by an arbitrary sale quantity',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a', quantity: null), expectedRevision: 0);

        await expectLater(
          controller.recordSale('a', quantity: 2, markSoldOut: true),
          throwsFormatException,
        );
        expect(controller.snapshot.revision, 1);
        expect(controller.snapshot.records['a']!.quantity, isNull);
        expect(controller.snapshot.records['a']!.sold, isFalse);
        expect(controller.sales, isEmpty);
      },
    );
  });

  group('bulk and persistence safety kernel', () {
    test(
      'bulk removal is tied to the exact reviewed active snapshot',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a'), expectedRevision: 0);
        await controller.save(stock('b'), expectedRevision: 1);
        final stale = controller.reviewArchiveAll();
        expect(stale.activeCount, 2);

        await controller.save(stock('c'), expectedRevision: 2);
        await expectLater(controller.applyArchiveAll(stale), throwsStateError);
        expect(controller.records.where((m) => !m.archived), hasLength(3));

        final fresh = controller.reviewArchiveAll();
        await controller.applyArchiveAll(fresh);
        expect(controller.records.where((m) => !m.archived), isEmpty);
        await controller.undo();
        expect(controller.records.where((m) => !m.archived), hasLength(3));
      },
    );

    test('legacy direct bulk mutation gateway fails closed', () async {
      final controller = await controllerWithClock();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);
      await expectLater(controller.archiveAll(), throwsStateError);
      expect(controller.snapshot.records['a']!.archived, isFalse);
    });

    test('storage rejects duplicate or contradictory mutation IDs', () async {
      final storage = MemoryInventoryStorage();
      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'duplicate caller bug',
            upserts: [stock('same'), stock('same')],
          ),
        ),
        throwsStateError,
      );
      expect((await storage.load()).revision, 0);

      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'contradictory caller bug',
            upserts: [stock('same')],
            removeIds: const ['same'],
          ),
        ),
        throwsStateError,
      );
      expect((await storage.load()).records, isEmpty);
    });
  });
}
