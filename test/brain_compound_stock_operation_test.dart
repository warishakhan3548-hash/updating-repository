import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/brain_compound_operations.dart';
import 'package:aaris_pharmacy/domain/brain_operations.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(
  String id, {
  int quantity = 10,
  bool sold = false,
  String location = 'Rack A',
}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'form': 'Tablet',
  'quantity': sold ? 0 : quantity,
  'expiry': '2027-12',
  'location': location,
  'sold': sold,
  'soldAt': sold ? '2026-09-09T10:00:00.000' : null,
  'soldQuantity': sold ? quantity : null,
  'revision': 1,
});

Future<PharmacyController> _controller() async {
  final controller = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  group('Aaris Brain atomic stock work command parser', () {
    test('accepts only stock adjustment plus location as two safe clauses', () {
      final command = parseBrainStockAdjustmentAndLocationCommand(
        'Dolo 650 stock add 5 units then location Rack C set karo',
      );
      expect(command, isNotNull);
      expect(command!.action, AppBrainAction.receiveStock);
      expect(command.query, 'Dolo 650');
      expect(command.quantity, 5);
      expect(command.locationPatch.location, 'Rack C');

      final reverse = parseBrainStockAdjustmentAndLocationCommand(
        'isko location Rack B set karo phir stock add ३ units',
      );
      expect(reverse, isNotNull);
      expect(reverse!.action, AppBrainAction.receiveStock);
      expect(reverse.quantity, 3);
      expect(isAppBrainContextReference(reverse.query), isTrue);
    });

    test(
      'different targets, choices and destructive compounds never stage',
      () {
        expect(
          parseBrainStockAdjustmentAndLocationCommand(
            'Dolo stock add 5 units then Crocin location Rack B set karo',
          ),
          isNull,
        );
        expect(
          parseBrainStockAdjustmentAndLocationCommand(
            'Dolo stock add 5 units or location Rack B set karo',
          ),
          isNull,
        );
        expect(
          parseBrainStockAdjustmentAndLocationCommand(
            'Dolo stock add 5 units then delete Dolo',
          ),
          isNull,
        );
        expect(
          parseAppBrainIntent('Dolo stock add 5 units then delete Dolo').action,
          AppBrainAction.safetyBlocked,
        );
      },
    );

    test(
      'future or negated clause cannot be upgraded into an atomic command',
      () {
        expect(
          parseBrainStockAdjustmentAndLocationCommand(
            'Dolo stock add 5 units tomorrow then location Rack B set karo',
          ),
          isNull,
        );
        expect(
          parseBrainStockAdjustmentAndLocationCommand(
            'Dolo quantity 20 set mat karo then location Rack B set karo',
          ),
          isNull,
        );
      },
    );
  });

  group('atomic stock and location transaction', () {
    test('updates both facts in one audited undoable commit', () async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      await controller.save(_stock('a'), expectedRevision: 0);

      final review = controller.reviewStockAdjustmentAndLocation(
        'a',
        kind: StockAdjustmentKind.receive,
        quantity: 5,
        locationPatch: const StockLocationPatch(location: 'Rack C'),
      );
      expect(review.beforeQuantity, 10);
      expect(review.afterQuantity, 15);
      expect(review.beforeLocationDisplay, 'Rack A');
      expect(review.afterLocationDisplay, 'Rack C');

      await controller.applyStockAdjustmentAndLocation(review);
      final changed = controller.snapshot.records['a']!;
      expect(changed.quantity, 15);
      expect(changed.location, 'Rack C');
      expect(controller.sales, isEmpty);
      expect(
        controller.snapshot.events.first['label'],
        contains('Stock + location'),
      );

      await controller.undo();
      final restored = controller.snapshot.records['a']!;
      expect(restored.quantity, 10);
      expect(restored.location, 'Rack A');
    });

    test(
      'unrelated writes survive but exact target edits invalidate review',
      () async {
        final controller = await _controller();
        addTearDown(controller.dispose);
        await controller.save(_stock('a'), expectedRevision: 0);
        final review = controller.reviewStockAdjustmentAndLocation(
          'a',
          kind: StockAdjustmentKind.receive,
          quantity: 2,
          locationPatch: const StockLocationPatch(location: 'Rack B'),
        );
        await controller.save(_stock('b'), expectedRevision: 1);

        await controller.applyStockAdjustmentAndLocation(review);
        expect(controller.snapshot.records['a']!.quantity, 12);
        expect(controller.snapshot.records['a']!.location, 'Rack B');

        final stale = controller.reviewStockAdjustmentAndLocation(
          'a',
          kind: StockAdjustmentKind.setExact,
          quantity: 20,
          locationPatch: const StockLocationPatch(location: 'Rack C'),
        );
        final live = controller.snapshot.records['a']!;
        await controller.save(
          live.patch({'notes': 'physical count changed after review'}),
          expectedRevision: controller.snapshot.revision,
        );
        await expectLater(
          controller.applyStockAdjustmentAndLocation(stale),
          throwsStateError,
        );
        expect(controller.snapshot.records['a']!.quantity, 12);
        expect(controller.snapshot.records['a']!.location, 'Rack B');
      },
    );

    test(
      'receiving SOLD stock reopens it without deleting sales history',
      () async {
        final controller = await _controller();
        addTearDown(controller.dispose);
        await controller.save(_stock('a', quantity: 6), expectedRevision: 0);
        await controller.recordSale(
          'a',
          quantity: 6,
          markSoldOut: true,
          totalAmountPaise: 6000,
        );
        expect(controller.sales, hasLength(1));

        final review = controller.reviewStockAdjustmentAndLocation(
          'a',
          kind: StockAdjustmentKind.receive,
          quantity: 8,
          locationPatch: const StockLocationPatch(location: 'Rack D'),
        );
        await controller.applyStockAdjustmentAndLocation(review);
        final reopened = controller.snapshot.records['a']!;
        expect(reopened.sold, isFalse);
        expect(reopened.quantity, 8);
        expect(reopened.location, 'Rack D');
        expect(controller.sales, hasLength(1));
      },
    );

    test(
      'exact correction plus location never invents SOLD or a sale',
      () async {
        final controller = await _controller();
        addTearDown(controller.dispose);
        await controller.save(_stock('a'), expectedRevision: 0);
        final review = controller.reviewStockAdjustmentAndLocation(
          'a',
          kind: StockAdjustmentKind.setExact,
          quantity: 0,
          locationPatch: const StockLocationPatch(location: 'Count Desk'),
        );
        await controller.applyStockAdjustmentAndLocation(review);
        final changed = controller.snapshot.records['a']!;
        expect(changed.quantity, 0);
        expect(changed.sold, isFalse);
        expect(changed.location, 'Count Desk');
        expect(controller.sales, isEmpty);
      },
    );
  });
}
