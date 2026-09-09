import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import '../lib/data/inventory_database.dart';
import '../lib/domain/ai_protocol.dart';
import '../lib/domain/inventory.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/search.dart';
import '../lib/domain/tracking.dart';
import '../lib/services/search_worker.dart';
import '../lib/state/pharmacy_controller.dart';
import 'domain_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('decimal strengths remain distinct throughout inventory identity', () {
    final records = [stock('a', strength: '2.5mg'), stock('b', strength: '25mg')];
    expect(records[0].identity, isNot(records[1].identity));
    expect(InventoryStats(records, contractToday).uniqueMedicines, 2);
    expect(stock('c', strength: '2.5 mg').identity, records[0].identity);
  });
  test('candidate limit keeps nearest equal-name stock regardless of input order', () {
    final records = List.generate(360, (i) => stock('stock_$i',
      expiry: dateText(civilDay(contractToday).add(Duration(days: 360 - i))),
    ));
    for (final input in [records, records.reversed.toList()]) {
      final hits = MedicineSearch(input).search(
        'Paracetamol', SearchScope.all, contractSettings, contractToday,
      );
      expect(hits.first.id, 'stock_359');
    }
  });
  test('numeric note searches use the matching field and preserve scope', () {
    final records = [
      stock('correct', notes: 'Room 2', expiry: '2027-01-01'),
      stock('wrong', notes: 'Room 3', expiry: '2026-09-08'),
      stock('expired', notes: 'Room 2', expiry: '2026-01-01'),
    ];
    final engine = MedicineSearch(records);
    final hits = engine.search('Room 2', SearchScope.all, contractSettings, contractToday);
    expect(hits.map((h) => h.id), contains('correct'));
    expect(hits.map((h) => h.id), isNot(contains('wrong')));
    final scoped = engine.search('Room 2', SearchScope.expired, contractSettings, contractToday);
    expect(scoped.single.id, 'expired');
  });
  test('stock ordering has a deterministic final ID tie break', () {
    final records = [stock('b'), stock('a')]
      ..sort((a, b) => expiryOrder(a, b, contractToday));
    expect(records.map((m) => m.id), ['a', 'b']);
  });
  test('only expired inventory creates reorder without silently marking SOLD', () {
    final record = stock('expired', quantity: 100, expiry: '2026-09-06');
    final stats = TrackingStats(medicines: [record], sales: const [],
      range: TrackingRange.lastDays(DateTime(2026, 8, 1), 7), today: contractToday);
    expect(stats.reorder.single.currentQuantity, 0);
    expect(stats.reorder.single.priority, ReorderPriority.urgent);
    expect(stats.reorder.single.reason, 'Only expired stock remains');
    expect(record.sold, false);
  });
  test('unknown unexpired stock is not assumed sold or zero', () {
    final stats = TrackingStats(medicines: [
      stock('expired', quantity: 100, expiry: '2026-01-01'),
      stock('unknown', quantity: null, expiry: '2027-01-01'),
    ], sales: const [], range: TrackingRange.lastDays(contractToday, 30),
      today: contractToday);
    expect(stats.reorder, isEmpty);
    expect(stats.movements.values.single.currentQuantity, isNull);
  });
  test('a stale editor cannot archive or record a sale after another edit', () async {
    final controller = PharmacyController(MemoryInventoryStorage(),
      clock: () => contractToday, backgroundSearch: false);
    await controller.initialize();
    addTearDown(controller.dispose);
    await controller.save(stock('a'), expectedRevision: 0);
    final reviewed = controller.snapshot.revision;
    await controller.save(controller.records.single.patch({'quantity': 20}),
      expectedRevision: reviewed);
    await expectLater(controller.archive('a', 'Correction', expectedRevision: reviewed), throwsStateError);
    await expectLater(controller.recordSale('a', quantity: 1, expectedRevision: reviewed), throwsStateError);
    await expectLater(controller.archiveAll(expectedRevision: reviewed), throwsStateError);
    expect(controller.records.single.archived, false);
    expect(controller.records.single.quantity, 20);
    expect(controller.sales, isEmpty);
  });
  test('AI selected actions are frozen before asynchronous preparation', () async {
    final controller = PharmacyController(MemoryInventoryStorage(),
      clock: () => contractToday, backgroundSearch: false);
    await controller.initialize();
    addTearDown(controller.dispose);
    final plan = controller.review(jsonEncode({
      'schema': pharmacySchema, 'requestId': 'frozen_selection',
      'baseRevision': 0, 'actions': List.generate(26, (i) => {
        'op': 'add', 'fields': {'name': 'Medicine $i'},
      }),
    }));
    final selected = <int>{25};
    final saving = controller.applyAi(plan, selected);
    selected.clear();
    await saving;
    expect(controller.records.single.name, 'Medicine 25');
  });
  test('worker close during startup settles requests without a hang', () async {
    for (final duringStart in [false, true]) {
      final worker = SearchWorker();
      final future = worker.search([stock('a')], 1, '', SearchScope.all,
        contractSettings, contractToday);
      final checked = future.then<void>((_) {}, onError: (Object error, StackTrace stack) {
        expect(error, isA<StateError>());
      });
      if (duringStart) await Future<void>.delayed(Duration.zero);
      worker.close();
      await checked.timeout(const Duration(seconds: 5));
      worker.close();
    }
  });
}
