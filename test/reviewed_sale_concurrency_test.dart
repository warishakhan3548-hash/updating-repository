import 'dart:async';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/supplier.dart';
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


class _FirstCommitGateStorage implements InventoryStorage {
  _FirstCommitGateStorage(InventorySnapshot initial)
    : _inner = MemoryInventoryStorage(initial);

  final MemoryInventoryStorage _inner;
  final Completer<void> _firstCommitGate = Completer<void>();
  int commits = 0;

  void releaseFirstCommit() {
    if (!_firstCommitGate.isCompleted) _firstCommitGate.complete();
  }

  @override
  Future<InventorySnapshot> load() => _inner.load();

  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) async {
    commits++;
    if (commits == 1) await _firstCommitGate.future;
    return _inner.commit(mutation);
  }

  @override
  Future<void> close() => _inner.close();
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

    test('survives an unrelated write already queued ahead of apply', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a'), expectedRevision: 0);
      final review = value.reviewSale('a', quantity: 2);

      final unrelated = value.save(
        stock('b', name: 'Crocin'),
        expectedRevision: value.snapshot.revision,
      );
      final applied = value.applySale(review);
      await Future.wait<void>(<Future<void>>[unrelated, applied]);

      expect(value.snapshot.revision, 3);
      expect(value.snapshot.records['a']!.quantity, 8);
      expect(value.snapshot.records['b']!.quantity, 10);
      expect(value.sales.single.quantity, 2);
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

  group('serialized editor saves', () {
    test('medicine save survives an unrelated write queued ahead', () async {
      final original = stock('a');
      final storage = _FirstCommitGateStorage(
        InventorySnapshot(records: <String, Medicine>{original.id: original}),
      );
      final value = PharmacyController(
        storage,
        clock: () => DateTime(2026, 9, 10, 12),
        backgroundSearch: false,
      );
      addTearDown(value.dispose);
      await value.initialize();

      final unrelated = value.save(
        stock('b', name: 'Crocin'),
        expectedRevision: 0,
      );
      final edited = value.save(
        original.patch(<String, dynamic>{'notes': 'Rack rechecked'}),
        expectedRevision: 0,
      );

      storage.releaseFirstCommit();
      await Future.wait<void>(<Future<void>>[unrelated, edited]);

      expect(value.snapshot.revision, 2);
      expect(value.snapshot.records['b']?.name, 'Crocin');
      expect(value.snapshot.records['a']?.notes, 'Rack rechecked');
      expect(storage.commits, 2);
    });

    test('medicine save rejects its row changing while queued', () async {
      final original = stock('a');
      final storage = _FirstCommitGateStorage(
        InventorySnapshot(records: <String, Medicine>{original.id: original}),
      );
      final value = PharmacyController(
        storage,
        clock: () => DateTime(2026, 9, 10, 12),
        backgroundSearch: false,
      );
      addTearDown(value.dispose);
      await value.initialize();

      final first = value.save(
        original.patch(<String, dynamic>{'notes': 'First edit'}),
        expectedRevision: 0,
      );
      final stale = value.save(
        original.patch(<String, dynamic>{'notes': 'Stale edit'}),
        expectedRevision: 0,
      );

      storage.releaseFirstCommit();
      await first;
      await expectLater(stale, throwsStateError);

      expect(value.snapshot.revision, 1);
      expect(value.snapshot.records['a']?.notes, 'First edit');
      expect(storage.commits, 1);
    });

    test('supplier save survives unrelated stock write queued ahead', () async {
      const supplier = Supplier(
        id: 'supplier-a',
        name: 'ABC Pharma',
        returnBeforeExpiryDays: 30,
      );
      final storage = _FirstCommitGateStorage(
        InventorySnapshot(
          suppliers: const <String, Supplier>{'supplier-a': supplier},
        ),
      );
      final value = PharmacyController(
        storage,
        clock: () => DateTime(2026, 9, 10, 12),
        backgroundSearch: false,
      );
      addTearDown(value.dispose);
      await value.initialize();

      final unrelated = value.save(
        stock('b', name: 'Crocin'),
        expectedRevision: 0,
      );
      final edited = value.saveSupplier(
        supplier.patch(<String, dynamic>{'returnBeforeExpiryDays': 45}),
        expectedRevision: 0,
      );

      storage.releaseFirstCommit();
      await Future.wait<void>(<Future<void>>[unrelated, edited]);

      expect(value.snapshot.revision, 2);
      expect(
        value.snapshot.suppliers['supplier-a']?.returnBeforeExpiryDays,
        45,
      );
      expect(storage.commits, 2);
    });

    test('supplier save rejects its supplier changing while queued', () async {
      const supplier = Supplier(
        id: 'supplier-a',
        name: 'ABC Pharma',
        returnBeforeExpiryDays: 30,
      );
      final storage = _FirstCommitGateStorage(
        InventorySnapshot(
          suppliers: const <String, Supplier>{'supplier-a': supplier},
        ),
      );
      final value = PharmacyController(
        storage,
        clock: () => DateTime(2026, 9, 10, 12),
        backgroundSearch: false,
      );
      addTearDown(value.dispose);
      await value.initialize();

      final first = value.saveSupplier(
        supplier.patch(<String, dynamic>{'returnBeforeExpiryDays': 45}),
        expectedRevision: 0,
      );
      final stale = value.saveSupplier(
        supplier.patch(<String, dynamic>{'returnBeforeExpiryDays': 60}),
        expectedRevision: 0,
      );

      storage.releaseFirstCommit();
      await first;
      await expectLater(stale, throwsStateError);

      expect(value.snapshot.revision, 1);
      expect(
        value.snapshot.suppliers['supplier-a']?.returnBeforeExpiryDays,
        45,
      );
      expect(storage.commits, 1);
    });
  });

}
