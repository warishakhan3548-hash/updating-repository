import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/inventory.dart';
import '../lib/domain/ai_protocol.dart';
import '../lib/domain/tracking.dart';
import '../lib/state/pharmacy_controller.dart';
import 'domain_contract.dart';

class _DelayedInventoryStorage implements InventoryStorage {
  final loadResult = Completer<InventorySnapshot>();
  int closeCalls = 0;

  @override
  Future<InventorySnapshot> load() => loadResult.future;

  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

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
  test('version-one database migrates without losing medicine facts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pharmacy_migration_test_',
    );
    final path = '${directory.path}/inventory.db';
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE medicines (id TEXT PRIMARY KEY, facts TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, settings TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE receipts (request_id TEXT PRIMARY KEY)',
          );
          await db.execute(
            'CREATE TABLE events (id TEXT PRIMARY KEY, revision INTEGER UNIQUE NOT NULL, detail TEXT NOT NULL, sold_value INTEGER NOT NULL, unknown_sold INTEGER NOT NULL, undone INTEGER NOT NULL DEFAULT 0)',
          );
          await db.insert('meta', {
            'id': 1,
            'revision': 0,
            'settings': jsonEncode(const WarningSettings().toJson()),
          });
          final medicine = stock('legacy');
          await db.insert('medicines', {
            'id': medicine.id,
            'facts': jsonEncode(medicine.toJson()),
          });
        },
      ),
    );
    await legacy.close();

    final upgraded = SqliteInventoryStorage(
      path: path,
      factory: databaseFactoryFfi,
    );
    final restored = await upgraded.load();
    expect(restored.records['legacy']!.name, 'Paracetamol');
    expect(restored.sales, isEmpty);
    expect(restored.soldValue, 0);
    await upgraded.close();
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
  test(
    'dispose during startup waits for load and never publishes late state',
    () async {
      final delayed = _DelayedInventoryStorage();
      final local = PharmacyController(delayed, backgroundSearch: false);
      var publications = 0;
      local.addListener(() => publications++);
      final first = local.initialize();
      final sameLoad = local.initialize();
      local.dispose();
      delayed.loadResult.complete(InventorySnapshot(revision: 7));
      await Future.wait([first, sameLoad]);
      await Future<void>.delayed(Duration.zero);
      expect(local.ready, false);
      expect(publications, 0);
      expect(delayed.closeCalls, 1);
    },
  );
  test('sale, stock decrement and Undo commit atomically', () async {
    await controller.save(stock('a', quantity: 10), expectedRevision: 0);
    await controller.recordSale('a', quantity: 4, totalAmountPaise: 1200);
    expect(controller.snapshot.records['a']!.quantity, 6);
    expect(controller.sales.single.quantity, 4);
    expect(
      controller.tracking(TrackingRange.lastDays(contractToday, 30)).unitsSold,
      4,
    );
    await controller.undo();
    expect(controller.snapshot.records['a']!.quantity, 10);
    expect(controller.sales, isEmpty);
  });
  test('expired stock cannot become a current sale or SOLD state', () async {
    await controller.save(
      stock('expired', expiry: '2026-09-06'),
      expectedRevision: 0,
    );
    await expectLater(
      controller.recordSale('expired', quantity: 1),
      throwsFormatException,
    );
    await expectLater(controller.markSold('expired'), throwsFormatException);
    final record = controller.snapshot.records['expired']!;
    await expectLater(
      controller.save(
        record.patch({'sold': true, 'quantity': 0}),
        expectedRevision: controller.snapshot.revision,
      ),
      throwsFormatException,
    );
    expect(controller.snapshot.revision, 1);
    expect(controller.sales, isEmpty);
    expect(controller.list(SearchScope.expired).single.id, 'expired');
  });
  test(
    'expiry day allows a genuine historical sale but not a later one',
    () async {
      await controller.save(
        stock('historical', expiry: '2026-09-06'),
        expectedRevision: 0,
      );
      await controller.recordSale(
        'historical',
        quantity: 1,
        occurredAt: DateTime(2026, 9, 6, 23, 59),
      );
      expect(controller.sales.single.quantity, 1);
      await expectLater(
        controller.recordSale(
          'historical',
          quantity: 1,
          occurredAt: DateTime(2026, 9, 7),
        ),
        throwsFormatException,
      );
      expect(controller.snapshot.records['historical']!.quantity, 9);
      expect(controller.sales.length, 1);
    },
  );
  test('sale date cannot predate the manufacturing fact', () async {
    final manufactured = Medicine.fromJson({
      ...stock('manufactured', expiry: '2026-10-01').toJson(),
      'mfg': '2026-09-05',
    });
    await controller.save(manufactured, expectedRevision: 0);
    await expectLater(
      controller.recordSale(
        'manufactured',
        quantity: 1,
        occurredAt: DateTime(2026, 9, 4),
      ),
      throwsFormatException,
    );
    expect(controller.sales, isEmpty);
  });
  test('controller exposes the deterministic FEFO stock choice', () async {
    await controller.save(
      stock('later', expiry: '2026-10-01'),
      expectedRevision: 0,
    );
    await controller.save(
      stock('first', expiry: '2026-09-08'),
      expectedRevision: 1,
    );
    await controller.save(stock('unknown', expiry: ''), expectedRevision: 2);
    expect(controller.preferredDispensingStock('later')!.id, 'first');
    expect(controller.dispensingChoices('later').map((record) => record.id), [
      'first',
      'later',
      'unknown',
    ]);
  });
  test('recorded sales survive a database reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pharmacy_sales_test_',
    );
    final path = '${directory.path}/inventory.db';
    final first = SqliteInventoryStorage(
      path: path,
      factory: databaseFactoryFfi,
    );
    final local = PharmacyController(
      first,
      clock: () => contractToday,
      backgroundSearch: false,
    );
    await local.initialize();
    await local.save(stock('a'), expectedRevision: 0);
    await local.recordSale('a', quantity: 2);
    await first.close();
    final second = SqliteInventoryStorage(
      path: path,
      factory: databaseFactoryFfi,
    );
    final restored = await second.load();
    expect(restored.sales.values.single.quantity, 2);
    expect(restored.records['a']!.quantity, 8);
    await second.close();
    local.dispose();
    await directory.delete(recursive: true);
  });
  test(
    'reviewed backup restore is atomic and keeps absent stock recoverable',
    () async {
      await controller.save(stock('original'), expectedRevision: 0);
      await controller.recordSale(
        'original',
        quantity: 2,
        totalAmountPaise: 500,
      );
      final backup = controller.createBackup().encode();
      await controller.save(
        stock('later', name: 'Later medicine'),
        expectedRevision: controller.snapshot.revision,
      );
      final review = await controller.reviewBackup(backup);
      await controller.restoreBackup(review);
      expect(controller.list(SearchScope.all).map((m) => m.id), ['original']);
      expect(controller.snapshot.records['later']!.archived, true);
      expect(controller.sales.single.quantity, 2);
      await controller.undo();
      expect(controller.snapshot.records['later']!.archived, false);
    },
  );
  test('medicine version history restores exact prior facts', () async {
    await controller.save(stock('a', quantity: 10), expectedRevision: 0);
    final edited = controller.snapshot.records['a']!.patch({
      'quantity': 3,
      'location': 'Rack 9',
    });
    await controller.save(edited, expectedRevision: 1);
    final version = controller.versionsFor('a').first;
    expect(version.record.quantity, 10);
    expect(version.record.location, '');
    await controller.restoreVersion(version);
    expect(controller.snapshot.records['a']!.quantity, 10);
    expect(controller.snapshot.records['a']!.location, '');
  });
}
