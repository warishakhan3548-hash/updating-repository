import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/inventory.dart';
import '../lib/domain/ai_protocol.dart';
import '../lib/state/pharmacy_controller.dart';
import 'domain_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late SqliteInventoryStorage storage;
  late PharmacyController controller;
  setUp(() async {
    storage = SqliteInventoryStorage(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    controller = PharmacyController(
      storage,
      clock: () => contractToday,
      backgroundSearch: false,
    );
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
  });
  test(
    'write commits once, rejects stale concurrent writer, and publishes committed data',
    () async {
      var publications = 0;
      controller.addListener(() => publications++);
      final first = controller.save(stock('a'), expectedRevision: 0);
      final second = controller.save(stock('b'), expectedRevision: 0);
      final rejected = expectLater(second, throwsStateError);
      await first;
      await rejected;
      expect(controller.snapshot.records.keys, ['a']);
      expect(publications, 1);
      expect((await storage.load()).revision, 1);
    },
  );
  test('invalid second row rolls back the entire SQL transaction', () async {
    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Invalid batch',
          upserts: [
            stock('valid'),
            Medicine(id: 'invalid', name: 'Invalid', quantity: -1),
          ],
        ),
      ),
      throwsFormatException,
    );
    final state = await storage.load();
    expect(state.records, isEmpty);
    expect(state.revision, 0);
    expect(state.events, isEmpty);
  });
  test('sold and restock preserve immutable amount estimate', () async {
    await controller.save(stock('a'), expectedRevision: 0);
    await controller.markSold('a');
    await controller.markSold('a');
    expect(controller.snapshot.soldValue, 2000);
    expect(controller.snapshot.revision, 2);
    expect(controller.list(SearchScope.sold).length, 1);
    final sold = controller.snapshot.records['a']!;
    await controller.save(
      sold.patch({
        'sold': false,
        'quantity': 20,
        'unitPricePaise': 900,
        'expiry': '2028-02',
        'soldAt': null,
        'soldQuantity': null,
        'soldUnitPricePaise': null,
      }),
      expectedRevision: 2,
    );
    expect(controller.snapshot.soldValue, 2000);
    expect(controller.list(SearchScope.sold), isEmpty);
    expect(controller.stats.onHandValue, 18000);
  });
  test('archive hides every view, undo restores the exact stock ID', () async {
    await controller.save(stock('a'), expectedRevision: 0);
    await controller.archive('a', 'Correction');
    expect(controller.list(SearchScope.all), isEmpty);
    expect(controller.stats.stockEntries, 0);
    await controller.undo();
    expect(controller.list(SearchScope.all).single.id, 'a');
    expect(controller.snapshot.records['a']!.archived, false);
  });
  test(
    'undo sold removes its amount estimate and restores prior quantity',
    () async {
      await controller.save(stock('a'), expectedRevision: 0);
      await controller.markSold('a');
      await controller.undo();
      expect(controller.snapshot.soldValue, 0);
      expect(controller.snapshot.records['a']!.quantity, 10);
      expect(controller.snapshot.records['a']!.sold, false);
    },
  );
  test('undo add removes the added record entirely', () async {
    await controller.save(stock('a'), expectedRevision: 0);
    await controller.undo();
    expect(controller.snapshot.records, isEmpty);
  });
  test(
    'AI selected changes are atomic and request replay stays blocked after Undo',
    () async {
      final export = controller.export();
      final response = jsonEncode({
        'schema': pharmacySchema,
        'requestId': export.requestId,
        'baseRevision': 0,
        'actions': [
          {
            'op': 'add',
            'fields': {'name': 'First'},
          },
          {
            'op': 'add',
            'fields': {'name': 'Second'},
          },
        ],
      });
      final plan = controller.review(response);
      await controller.applyAi(plan, {0});
      expect(controller.records.single.name, 'First');
      expect(controller.snapshot.receipts, contains(export.requestId));
      await controller.undo();
      expect(controller.records, isEmpty);
      final retry = jsonDecode(response) as Map<String, dynamic>;
      retry['baseRevision'] = controller.snapshot.revision;
      expect(() => controller.review(jsonEncode(retry)), throwsFormatException);
    },
  );
  test('cancel a multi-batch AI preparation before any write', () async {
    final export = controller.export();
    final plan = controller.review(
      jsonEncode({
        'schema': pharmacySchema,
        'requestId': export.requestId,
        'baseRevision': 0,
        'actions': List.generate(
          80,
          (i) => {
            'op': 'add',
            'fields': {'name': 'Medicine $i'},
          },
        ),
      }),
    );
    final applying = controller.applyAi(plan, {for (var i = 0; i < 80; i++) i});
    final rejected = expectLater(applying, throwsStateError);
    controller.cancelAi();
    await rejected;
    expect(controller.snapshot.revision, 0);
    expect(controller.records, isEmpty);
    expect(controller.snapshot.receipts, isEmpty);
  });
  test('AI approved plan cannot overwrite later manual work', () async {
    final data = controller.export();
    final plan = controller.review(
      jsonEncode({
        'schema': pharmacySchema,
        'requestId': data.requestId,
        'baseRevision': 0,
        'actions': [
          {
            'op': 'add',
            'fields': {'name': 'From AI'},
          },
        ],
      }),
    );
    await controller.save(stock('manual'), expectedRevision: 0);
    await expectLater(controller.applyAi(plan, {0}), throwsStateError);
    expect(controller.records.single.id, 'manual');
  });
  test('disk reopen preserves settings, medicines and receipt', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pharmacy_db_test_',
    );
    final path = '${directory.path}/inventory.db';
    final first = SqliteInventoryStorage(
      path: path,
      factory: databaseFactoryFfi,
    );
    await first.load();
    await first.commit(
      InventoryMutation(
        expectedRevision: 0,
        label: 'Import',
        upserts: [stock('durable')],
        requestId: 'durable_request',
        settings: const WarningSettings(shortDays: 5, months: 3),
      ),
    );
    await first.close();
    final second = SqliteInventoryStorage(
      path: path,
      factory: databaseFactoryFfi,
    );
    final restored = await second.load();
    expect(restored.records['durable']!.quantity, 10);
    expect(restored.settings.shortDays, 5);
    expect(restored.receipts, contains('durable_request'));
    expect(restored.events.length, 1);
    await second.close();
    await directory.delete(recursive: true);
  });
  test('date refresh moves an entry without database writes', () async {
    var now = DateTime(2026, 9, 7);
    final local = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => now,
      backgroundSearch: false,
    );
    await local.initialize();
    await local.save(stock('a', expiry: '2026-09-07'), expectedRevision: 0);
    expect(local.list(SearchScope.expired), isEmpty);
    now = DateTime(2026, 9, 8);
    local.refreshDay();
    expect(local.list(SearchScope.expired).single.id, 'a');
    expect(local.snapshot.revision, 1);
    local.dispose();
  });
}
