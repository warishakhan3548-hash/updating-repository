import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/brain_operations.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/state/stock_location_operations.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(String id, {bool sold = false}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'form': 'Tablet',
  'quantity': sold ? 0 : 10,
  'expiry': '2027-12',
  'block': 'A1',
  'row': 'R1',
  'vertical': 'V1',
  'location': 'Front shelf',
  'sold': sold,
  'soldAt': sold ? '2026-09-09T10:00:00.000' : null,
  'soldQuantity': sold ? 10 : null,
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
  group('Aaris Brain location command parsing', () {
    test(
      'parses structured partial relocation without touching medicine strength',
      () {
        final intent = parseAppBrainIntent(
          'Dolo 650 location Block B2 Row R4 Vertical V3 set karo',
        );
        expect(intent.action, AppBrainAction.relocateMedicine);
        expect(intent.query, 'Dolo 650');
        expect(intent.locationPatch?.block, 'B2');
        expect(intent.locationPatch?.row, 'R4');
        expect(intent.locationPatch?.vertical, 'V3');
        expect(intent.locationPatch?.location, isNull);
        expect(intent.destructive, isFalse);
        expect(intent.mutatesInventory, isTrue);
      },
    );

    test('supports exact context and free-form shelf destinations', () {
      final intent = parseAppBrainIntent('isko shelf Cold Cabinet 2 set karo');
      expect(intent.action, AppBrainAction.relocateMedicine);
      expect(intent.query, 'isko');
      expect(isAppBrainContextReference(intent.query), isTrue);
      expect(intent.locationPatch?.location, 'Cold Cabinet 2');
    });

    test('location clear is relocation, never a medicine delete command', () {
      final intent = parseAppBrainIntent('Dolo 650 location hata do');
      expect(intent.action, AppBrainAction.relocateMedicine);
      expect(intent.query, 'Dolo 650');
      expect(intent.locationPatch?.clearsEverything, isTrue);
    });

    test('plain location question remains a read-only operational brief', () {
      final intent = parseAppBrainIntent('Dolo 650 kahan hai');
      expect(intent.action, AppBrainAction.search);
      expect(intent.locationPatch, isNull);
    });
  });

  group('reviewed stock relocation', () {
    test(
      'relocation is revision-bound, partial, atomic and undoable',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a'), expectedRevision: 0);

        final review = controller.reviewStockLocationUpdate(
          'a',
          const StockLocationPatch(block: 'B8', row: 'R2'),
        );
        expect(review.beforeDisplay, contains('Block A1'));
        expect(review.afterDisplay, contains('Block B8'));
        expect(review.afterVertical, 'V1');
        expect(review.afterLocation, 'Front shelf');

        await controller.applyStockLocationUpdate(review);
        final moved = controller.snapshot.records['a']!;
        expect(moved.block, 'B8');
        expect(moved.row, 'R2');
        expect(moved.vertical, 'V1');
        expect(moved.location, 'Front shelf');
        expect(controller.sales, isEmpty);

        await controller.undo();
        expect(controller.snapshot.records['a']!.block, 'A1');
        expect(controller.snapshot.records['a']!.row, 'R1');
      },
    );

    test(
      'stale review cannot overwrite a concurrent inventory change',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('a'), expectedRevision: 0);
        final review = controller.reviewStockLocationUpdate(
          'a',
          const StockLocationPatch(location: 'Back shelf'),
        );
        await controller.save(stock('b'), expectedRevision: 1);

        await expectLater(
          controller.applyStockLocationUpdate(review),
          throwsStateError,
        );
        expect(controller.snapshot.records['a']!.location, 'Front shelf');
      },
    );

    test(
      'SOLD entries cannot be relocated as if physical stock exists',
      () async {
        final controller = await controllerWithClock();
        addTearDown(controller.dispose);
        await controller.save(stock('sold', sold: true), expectedRevision: 0);

        expect(
          () => controller.reviewStockLocationUpdate(
            'sold',
            const StockLocationPatch(block: 'B2'),
          ),
          throwsStateError,
        );
      },
    );
  });

  group('explicit removal reason extraction', () {
    test('reason is bounded and stripped from medicine target', () {
      final damaged = parseAppBrainIntent('Dolo 650 damaged remove karo');
      expect(damaged.action, AppBrainAction.removeMedicine);
      expect(damaged.query, 'Dolo 650');
      expect(damaged.removalReason, RemovalReasonHint.damaged);

      final expired = parseAppBrainIntent('expired Dolo 650 delete karo');
      expect(expired.query, 'Dolo 650');
      expect(expired.removalReason, RemovalReasonHint.expired);
    });

    test('sold removal hint stays an explicit SOLD workflow hint', () {
      final intent = parseAppBrainIntent('Dolo 650 sold remove karo');
      expect(intent.action, AppBrainAction.removeMedicine);
      expect(intent.query, 'Dolo 650');
      expect(intent.removalReason, RemovalReasonHint.soldOut);
    });
  });
}
