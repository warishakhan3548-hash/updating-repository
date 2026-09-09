import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/automation_guard.dart';
import '../domain/medicine.dart';
import '../domain/inventory.dart';
import '../domain/tracking.dart';

class InventorySnapshot {
  InventorySnapshot({
    this.revision = 0,
    this.settings = const WarningSettings(),
    Map<String, Medicine>? records,
    Map<String, SaleEvent>? sales,
    Set<String>? receipts,
    List<Map<String, dynamic>>? events,
    this.soldValue = 0,
    this.unknownSold = 0,
  }) : records = Map.unmodifiable(records ?? {}),
       sales = Map.unmodifiable(sales ?? {}),
       receipts = Set.unmodifiable(receipts ?? {}),
       events = List.unmodifiable(events ?? []);
  final int revision, soldValue, unknownSold;
  final WarningSettings settings;
  final Map<String, Medicine> records;
  final Map<String, SaleEvent> sales;
  final Set<String> receipts;
  final List<Map<String, dynamic>> events;
}

class InventoryMutation {
  InventoryMutation({
    required this.expectedRevision,
    required this.label,
    required this.upserts,
    this.upsertSales = const [],
    this.removeIds = const [],
    this.removeSaleIds = const [],
    this.settings,
    this.requestId,
    this.undoEventId,
    this.undoable = true,
    this.soldValueOverride,
    this.unknownSoldOverride,
  });
  final int expectedRevision;
  final String label;
  final List<Medicine> upserts;
  final List<SaleEvent> upsertSales;
  final List<String> removeIds;
  final List<String> removeSaleIds;
  final WarningSettings? settings;
  final String? requestId, undoEventId;
  final bool undoable;
  final int? soldValueOverride, unknownSoldOverride;
}

abstract class InventoryStorage {
  Future<InventorySnapshot> load();
  Future<InventorySnapshot> commit(InventoryMutation mutation);
  Future<void> close();
}

void _validateMutationShape(InventoryMutation mutation) {
  if (mutation.expectedRevision < 0) {
    throw const FormatException('Invalid inventory revision.');
  }
  final label = mutation.label.trim();
  if (label.isEmpty || label.length > 1200) {
    throw const FormatException('Invalid inventory activity label.');
  }

  Set<String> uniqueIds(Iterable<String> values, String description) {
    final list = values.toList(growable: false);
    if (list.any((id) => id.trim().isEmpty || id.length > 300)) {
      throw FormatException('Invalid $description ID.');
    }
    final ids = list.toSet();
    if (ids.length != list.length) {
      throw StateError('One inventory transaction cannot repeat a $description ID.');
    }
    return ids;
  }

  final upsertIds = uniqueIds(
    mutation.upserts.map((record) => record.id),
    'medicine upsert',
  );
  final removeIds = uniqueIds(mutation.removeIds, 'medicine removal');
  if (upsertIds.intersection(removeIds).isNotEmpty) {
    throw StateError(
      'One inventory transaction cannot both upsert and remove the same medicine ID.',
    );
  }

  final upsertSaleIds = uniqueIds(
    mutation.upsertSales.map((sale) => sale.id),
    'sale upsert',
  );
  final removeSaleIds = uniqueIds(mutation.removeSaleIds, 'sale removal');
  if (upsertSaleIds.intersection(removeSaleIds).isNotEmpty) {
    throw StateError(
      'One inventory transaction cannot both upsert and remove the same sale ID.',
    );
  }

  for (final entry in <String, String?>{
    'AI request': mutation.requestId,
    'undo event': mutation.undoEventId,
  }.entries) {
    final value = entry.value;
    if (value != null && (value.trim().isEmpty || value.length > 300)) {
      throw FormatException('Invalid ${entry.key} ID.');
    }
  }
}

Map<String, dynamic> makeEvent(
  InventorySnapshot before,
  InventoryMutation mutation,
) {
  var soldValue = 0, unknownSold = 0;
  for (final m in mutation.upserts) {
    if (mutation.undoEventId == null &&
        m.sold &&
        before.records[m.id]?.sold != true) {
      if (m.soldQuantity != null && m.soldUnitPricePaise != null) {
        soldValue = checkedMoneySum(
          soldValue,
          stockValue(m.soldQuantity!, m.soldUnitPricePaise!),
        );
      } else {
        unknownSold++;
      }
    }
  }
  checkedMoneySum(before.soldValue, soldValue);
  return {
    'id': newId(),
    'revision': before.revision + 1,
    'label': mutation.label,
    'time': DateTime.now().toIso8601String(),
    'undoable': mutation.undoable,
    'undone': false,
    'before': {
      for (final id in {
        ...mutation.upserts.map((m) => m.id),
        ...mutation.removeIds,
      })
        id: before.records[id]?.toJson(),
    },
    'salesBefore': {
      for (final id in {
        ...mutation.upsertSales.map((sale) => sale.id),
        ...mutation.removeSaleIds,
      })
        id: before.sales[id]?.toJson(),
    },
    'settingsBefore': before.settings.toJson(),
    'soldValue': soldValue,
    'unknownSold': unknownSold,
    'soldValueBeforeTotal': before.soldValue,
    'unknownSoldBeforeTotal': before.unknownSold,
  };
}

InventorySnapshot nextSnapshot(
  InventorySnapshot before,
  InventoryMutation mutation,
  Map<String, dynamic> event,
) {
  final records = {...before.records};
  final sales = {...before.sales};
  for (final record in mutation.upserts) {
    records[record.id] = Medicine.fromJson(record.toJson());
  }
  for (final id in mutation.removeIds) {
    records.remove(id);
  }

  // Cross-row integrity is enforced at the same authoritative boundary as
  // revision, money and schema validation. This closes the gap where Attention
  // could correctly flag one physical lot with contradictory batch facts while
  // a later sale/receive/SOLD path still mutated that row. Undo must faithfully
  // restore the immediately previous state, and an explicitly reviewed backup
  // restore must reproduce its source snapshot, so those two recovery paths are
  // intentionally exempt from this prospective guard.
  final recoveryRestore =
      mutation.soldValueOverride != null || mutation.unknownSoldOverride != null;
  if (mutation.undoEventId == null && !recoveryRestore) {
    ensureIntegritySafeInventoryMutation(
      before: before.records,
      after: records,
      touchedStockIds: {
        ...mutation.upserts.map((record) => record.id),
        ...mutation.removeIds,
      },
      today: DateTime.now(),
    );
  }

  for (final sale in mutation.upsertSales) {
    sales[sale.id] = SaleEvent.fromJson(sale.toJson());
  }
  for (final id in mutation.removeSaleIds) {
    sales.remove(id);
  }
  // Validate aggregate money before committing, not while a statistics widget renders.
  InventoryStats(records.values, DateTime.now());
  var total =
      mutation.soldValueOverride ??
      checkedMoneySum(before.soldValue, event['soldValue'] as int);
  var missing =
      mutation.unknownSoldOverride ??
      before.unknownSold + (event['unknownSold'] as int);
  if (total < 0 || total > maxExactPaise || missing < 0) {
    throw const FormatException('Invalid sold-stock totals.');
  }
  if (mutation.undoEventId != null) {
    final undone = before.events
        .where(
          (e) =>
              e['id'] == mutation.undoEventId &&
              e['revision'] == before.revision &&
              e['undone'] != true,
        )
        .toList();
    if (undone.length != 1) throw StateError('Undo is no longer available.');
    total =
        undone.single['soldValueBeforeTotal'] as int? ??
        total - undone.single['soldValue'] as int;
    missing =
        undone.single['unknownSoldBeforeTotal'] as int? ??
        missing - undone.single['unknownSold'] as int;
  }
  return InventorySnapshot(
    revision: before.revision + 1,
    settings: WarningSettings.fromJson(
      (mutation.settings ?? before.settings).toJson(),
    ),
    records: records,
    sales: sales,
    receipts: {
      ...before.receipts,
      if (mutation.requestId != null) mutation.requestId!,
    },
    events: [
      event,
      ...before.events.map(
        (e) => e['id'] == mutation.undoEventId ? {...e, 'undone': true} : e,
      ),
    ].take(200).toList(),
    soldValue: total,
    unknownSold: missing,
  );
}

class SqliteInventoryStorage implements InventoryStorage {
  SqliteInventoryStorage({this.path, this.factory});
  final String? path;
  final DatabaseFactory? factory;
  Database? _db;
  InventorySnapshot? _cached;
  Future<Database> _open() async {
    if (_db != null) return _db!;
    final provider = factory ?? databaseFactory;
    final dbPath =
        path ?? '${await provider.getDatabasesPath()}/aaris_pharmacy_v1.db';
    _db = await provider.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE medicines (id TEXT PRIMARY KEY, facts TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, settings TEXT NOT NULL, sold_value INTEGER NOT NULL DEFAULT 0, unknown_sold INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE receipts (request_id TEXT PRIMARY KEY)',
          );
          await db.execute(
            'CREATE TABLE sales (id TEXT PRIMARY KEY, facts TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE events (id TEXT PRIMARY KEY, revision INTEGER UNIQUE NOT NULL, detail TEXT NOT NULL, sold_value INTEGER NOT NULL, unknown_sold INTEGER NOT NULL, undone INTEGER NOT NULL DEFAULT 0)',
          );
          await db.insert('meta', {
            'id': 1,
            'revision': 0,
            'settings': jsonEncode(const WarningSettings().toJson()),
            'sold_value': 0,
            'unknown_sold': 0,
          });
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'CREATE TABLE IF NOT EXISTS sales (id TEXT PRIMARY KEY, facts TEXT NOT NULL)',
            );
          }
          if (oldVersion < 3) {
            await db.execute(
              'ALTER TABLE meta ADD COLUMN sold_value INTEGER NOT NULL DEFAULT 0',
            );
            await db.execute(
              'ALTER TABLE meta ADD COLUMN unknown_sold INTEGER NOT NULL DEFAULT 0',
            );
            final totals = (await db.rawQuery(
              'SELECT COALESCE(SUM(sold_value),0) AS total, COALESCE(SUM(unknown_sold),0) AS missing FROM events WHERE undone=0',
            )).single;
            await db.update('meta', {
              'sold_value': totals['total'],
              'unknown_sold': totals['missing'],
            }, where: 'id=1');
          }
        },
      ),
    );
    return _db!;
  }

  Future<InventorySnapshot> _read(DatabaseExecutor db) async {
    final meta = (await db.query('meta', where: 'id=1')).single;
    final records = await db.query('medicines');
    final sales = await db.query('sales');
    final events = await db.query(
      'events',
      orderBy: 'revision DESC',
      limit: 200,
    );
    final receipts = await db.query('receipts');
    return InventorySnapshot(
      revision: meta['revision'] as int,
      settings: WarningSettings.fromJson(
        jsonDecode(meta['settings'] as String) as Map<String, dynamic>,
      ),
      records: {
        for (final row in records)
          row['id'] as String: Medicine.fromJson(
            jsonDecode(row['facts'] as String) as Map<String, dynamic>,
          ),
      },
      sales: {
        for (final row in sales)
          row['id'] as String: SaleEvent.fromJson(
            jsonDecode(row['facts'] as String) as Map<String, dynamic>,
          ),
      },
      receipts: receipts.map((r) => r['request_id'] as String).toSet(),
      events: events
          .map(
            (r) => {
              ...jsonDecode(r['detail'] as String) as Map<String, dynamic>,
              'undone': r['undone'] == 1,
            },
          )
          .toList(),
      soldValue: meta['sold_value'] as int,
      unknownSold: meta['unknown_sold'] as int,
    );
  }

  @override
  Future<InventorySnapshot> load() async =>
      _cached = await _read(await _open());
  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) async {
    final db = await _open();
    final result = await db.transaction((tx) async {
      final diskRevision =
          (await tx.query(
                'meta',
                columns: ['revision'],
                where: 'id=1',
              )).single['revision']
              as int;
      final before = _cached?.revision == diskRevision
          ? _cached!
          : await _read(tx);
      if (before.revision != mutation.expectedRevision)
        throw StateError(
          'Inventory changed. Reopen this review before saving.',
        );
      _validateMutationShape(mutation);
      if (mutation.requestId != null &&
          before.receipts.contains(mutation.requestId))
        throw StateError('This AI request has already been applied.');
      final event = makeEvent(before, mutation);
      final after = nextSnapshot(before, mutation, event);
      for (final m in mutation.upserts) {
        // Revalidate at the persistence boundary, including manual caller changes.
        final valid = Medicine.fromJson(m.toJson());
        await tx.insert('medicines', {
          'id': valid.id,
          'facts': jsonEncode(valid.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final id in mutation.removeIds) {
        await tx.delete('medicines', where: 'id=?', whereArgs: [id]);
      }
      for (final sale in mutation.upsertSales) {
        final valid = SaleEvent.fromJson(sale.toJson());
        await tx.insert('sales', {
          'id': valid.id,
          'facts': jsonEncode(valid.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final id in mutation.removeSaleIds) {
        await tx.delete('sales', where: 'id=?', whereArgs: [id]);
      }
      if (mutation.undoEventId != null) {
        final count = await tx.update(
          'events',
          {'undone': 1},
          where: 'id=? AND revision=? AND undone=0',
          whereArgs: [mutation.undoEventId, before.revision],
        );
        if (count != 1)
          throw StateError('Undo is no longer available for that change.');
      }
      await tx.update('meta', {
        'revision': before.revision + 1,
        'settings': jsonEncode((mutation.settings ?? before.settings).toJson()),
        'sold_value': after.soldValue,
        'unknown_sold': after.unknownSold,
      }, where: 'id=1');
      if (mutation.requestId != null)
        await tx.insert('receipts', {'request_id': mutation.requestId});
      await tx.insert('events', {
        'id': event['id'],
        'revision': event['revision'],
        'detail': jsonEncode(event),
        'sold_value': event['soldValue'],
        'unknown_sold': event['unknownSold'],
        'undone': 0,
      });
      await tx.rawDelete(
        'DELETE FROM events WHERE revision NOT IN '
        '(SELECT revision FROM events ORDER BY revision DESC LIMIT 200)',
      );
      return after;
    });
    _cached = result;
    return result;
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _cached = null;
  }
}

/// Used only for explicit demos and tests. Real mobile inventories use SQLite.
class MemoryInventoryStorage implements InventoryStorage {
  MemoryInventoryStorage([InventorySnapshot? initial])
    : _state = initial ?? InventorySnapshot();
  InventorySnapshot _state;
  @override
  Future<InventorySnapshot> load() async => _state;
  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) async {
    if (_state.revision != mutation.expectedRevision)
      throw StateError('Inventory changed. Reopen this review.');
    _validateMutationShape(mutation);
    if (mutation.requestId != null &&
        _state.receipts.contains(mutation.requestId))
      throw StateError('Request already applied.');
    final event = makeEvent(_state, mutation);
    _state = nextSnapshot(_state, mutation, event);
    return _state;
  }

  @override
  Future<void> close() async {}
}
