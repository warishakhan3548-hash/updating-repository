import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/supplier.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(String id, {String name = 'Dolo'}) => Medicine.fromJson(
      <String, dynamic>{
        'id': id,
        'name': name,
        'strength': '650 mg',
        'form': 'Tablet',
        'quantity': 10,
        'unitPricePaise': 500,
        'expiry': '2027-12',
        'revision': 1,
      },
    );

void main() {
  test('reviewed medicine edit survives an unrelated queued write', () async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => DateTime(2026, 9, 20, 12),
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.save(_stock('a'), expectedRevision: 0);

    final reviewed = controller.snapshot.records['a']!;
    final unrelated = controller.save(
      _stock('b', name: 'Crocin'),
      expectedRevision: controller.snapshot.revision,
    );
    final edited = controller.saveReviewedMedicine(
      reviewed: reviewed,
      draft: reviewed.patch(<String, dynamic>{'notes': 'Shelf verified'}),
    );

    await Future.wait<void>(<Future<void>>[unrelated, edited]);
    expect(controller.snapshot.records['a']!.notes, 'Shelf verified');
    expect(controller.snapshot.records['b']!.name, 'Crocin');
    expect(controller.snapshot.revision, 3);
  });

  test('reviewed medicine edit rejects a target row changed ahead of it', () async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => DateTime(2026, 9, 20, 12),
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.save(_stock('a'), expectedRevision: 0);

    final reviewed = controller.snapshot.records['a']!;
    final changed = controller.save(
      reviewed.patch(<String, dynamic>{'quantity': 9}),
      expectedRevision: controller.snapshot.revision,
    );
    final stale = controller.saveReviewedMedicine(
      reviewed: reviewed,
      draft: reviewed.patch(<String, dynamic>{'notes': 'stale editor'}),
    );

    await changed;
    await expectLater(stale, throwsStateError);
    expect(controller.snapshot.records['a']!.quantity, 9);
    expect(controller.snapshot.records['a']!.notes, isEmpty);
  });

  test('editor SOLD commit owns lifecycle facts and one business instant', () async {
    final scripted = <DateTime>[];
    final fallback = DateTime(2026, 9, 20, 12);
    DateTime clock() => scripted.isEmpty ? fallback : scripted.removeAt(0);

    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: clock,
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.save(_stock('a'), expectedRevision: 0);

    final reviewed = controller.snapshot.records['a']!;
    final draft = reviewed.patch(<String, dynamic>{
      'name': 'Dolo Edited',
      'quantity': 7,
      'unitPricePaise': 900,
    });
    final committedAt = DateTime(2026, 9, 19, 23, 59, 59);
    scripted.addAll(<DateTime>[
      committedAt,
      DateTime(2026, 9, 20, 0, 0, 1),
    ]);

    await controller.saveReviewedMedicine(
      reviewed: reviewed,
      draft: draft,
      markSold: true,
    );

    final sold = controller.snapshot.records['a']!;
    expect(sold.name, 'Dolo Edited');
    expect(sold.sold, isTrue);
    expect(sold.quantity, 0);
    expect(sold.soldQuantity, 7);
    expect(sold.soldUnitPricePaise, 900);
    expect(sold.soldAt, committedAt.toIso8601String());
    expect(
      controller.snapshot.events.first['time'],
      committedAt.toIso8601String(),
    );
    expect(controller.snapshot.events.first['businessDay'], '2026-09-19');
  });

  test('reviewed supplier edit survives unrelated queued inventory work', () async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => DateTime(2026, 9, 20, 12),
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    const supplier = Supplier(
      id: 'supplier_a',
      name: 'ABC Pharma',
      returnBeforeExpiryDays: 30,
    );
    await controller.saveSupplier(supplier, expectedRevision: 0);

    final reviewed = controller.snapshot.suppliers[supplier.id]!;
    final unrelated = controller.save(
      _stock('b'),
      expectedRevision: controller.snapshot.revision,
    );
    final edited = controller.saveReviewedSupplier(
      reviewed: reviewed,
      draft: reviewed.patch(<String, dynamic>{'address': 'Updated address'}),
    );

    await Future.wait<void>(<Future<void>>[unrelated, edited]);
    expect(
      controller.snapshot.suppliers[supplier.id]!.address,
      'Updated address',
    );
    expect(controller.snapshot.records['b']!.name, 'Dolo');
    expect(controller.snapshot.revision, 3);
  });
}
