import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(String id, {String name = 'Dolo', int? quantity = 10}) =>
    Medicine.fromJson({
      'id': id,
      'name': name,
      'strength': '650 mg',
      'form': 'Tablet',
      'quantity': quantity,
      'expiry': '2027-12',
      'revision': 1,
    });

Future<PharmacyController> controller() async {
  final value = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await value.initialize();
  return value;
}

void main() {
  group('dependency-scoped reviewed single-stock sale', () {
    test('survives unrelated inventory writes', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a'), expectedRevision: 0);
      final displayed = value.snapshot.records['a']!;
      final review = value.reviewSale(
        'a',
        quantity: 2,
        totalAmountPaise: 4200,
        reviewedRecord: displayed,
      );

      await value.save(
        stock('b', name: 'Crocin'),
        expectedRevision: value.snapshot.revision,
      );
      await value.applySale(review);

      expect(value.snapshot.records['a']!.quantity, 8);
      expect(value.snapshot.records['b']!.quantity, 10);
      expect(value.sales, hasLength(1));
      expect(value.sales.single.quantity, 2);
      expect(value.sales.single.totalAmountPaise, 4200);
    });

    test('rejects a target row changed after review', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a'), expectedRevision: 0);
      final review = value.reviewSale('a', quantity: 2);
      final live = value.snapshot.records['a']!;
      await value.save(
        live.patch({'notes': 'physical pack rechecked'}),
        expectedRevision: value.snapshot.revision,
      );

      await expectLater(value.applySale(review), throwsStateError);
      expect(value.snapshot.records['a']!.quantity, 10);
      expect(value.sales, isEmpty);
    });

    test('rejects a stale editor snapshot before preparing the sale', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a'), expectedRevision: 0);
      final displayed = value.snapshot.records['a']!;
      await value.save(
        displayed.patch({'notes': 'changed elsewhere'}),
        expectedRevision: value.snapshot.revision,
      );

      expect(
        () => value.reviewSale('a', quantity: 1, reviewedRecord: displayed),
        throwsStateError,
      );
      expect(value.sales, isEmpty);
    });

    test('unknown stock cannot be silently marked sold out', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a', quantity: null), expectedRevision: 0);

      expect(
        () => value.reviewSale('a', quantity: 1, markSoldOut: true),
        throwsFormatException,
      );
      expect(value.snapshot.records['a']!.sold, isFalse);
      expect(value.sales, isEmpty);
    });

    test('reviewed sold-out sale remains atomic and undoable', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a', quantity: 3), expectedRevision: 0);
      final review = value.reviewSale(
        'a',
        quantity: 3,
        totalAmountPaise: 9000,
        markSoldOut: true,
      );
      await value.applySale(review);

      expect(value.snapshot.records['a']!.quantity, 0);
      expect(value.snapshot.records['a']!.sold, isTrue);
      expect(value.sales, hasLength(1));
      await value.undo();
      expect(value.snapshot.records['a']!.quantity, 3);
      expect(value.snapshot.records['a']!.sold, isFalse);
      expect(value.sales, isEmpty);
    });
  });
}
