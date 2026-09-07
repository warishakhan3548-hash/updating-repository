import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/medicine.dart';
import '../domain/inventory.dart';

class InventorySnapshot {
  InventorySnapshot({
    this.revision = 0,
    this.settings = const WarningSettings(),
    Map<String, Medicine>? records,
    Set<String>? receipts,
    List<Map<String, dynamic>>? events,
    this.soldValue = 0,
    this.unknownSold = 0,
  }) : records = Map.unmodifiable(records ?? {}),
       receipts = Set.unmodifiable(receipts ?? {}),
       events = List.unmodifiable(events ?? []);
  final int revision, soldValue, unknownSold;
  final WarningSettings settings;
  final Map<String, Medicine> records;
  final Set<String> receipts;
  final List<Map<String, dynamic>> events;
}

class InventoryMutation {
  InventoryMutation({
    required this.expectedRevision,
    required this.label,
    required this.upserts,
    this.removeIds = const [],
    this.settings,
    this.requestId,
    this.undoEventId,
    this.undoable = true,
  });
  final int expectedRevision;
  final String label;
  final List<Medicine> upserts;
  final List<String> removeIds;
  final WarningSettings? settings;
  final String? requestId, undoEventId;
  final bool undoable;
}

abstract class InventoryStorage {
  Future<InventorySnapshot> load();
  Future<InventorySnapshot> commit(InventoryMutation mutation);
  Future<void> close();
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
    'settingsBefore': before.settings.toJson(),
    'soldValue': soldValue,
    'unknownSold': unknownSold,
  };
}

InventorySnapshot nextSnapshot(
  InventorySnapshot before,
  InventoryMutation mutation,
  Map<String, dynamic> event,
) {
  final records = {...before.records};
  for (final record in mutation.upserts) {
    records[record.id] = Medicine.fromJson(record.toJson());
  }
  for (final id in mutation.removeIds) {
    records.remove(id);
  }
  // Validate aggregate money before committing, not while a statistics widget renders.
  InventoryStats(records.values, DateTime.now());
  var total = checkedMoneySum(before.soldValue, event['soldValue'] as int);
  var missing = before.unknownSold + (event['unknownSold'] as int);
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
    total -= undone.single['soldValue'] as int;
    missing -= undone.single['unknownSold'] as int;
  }
  return InventorySnapshot(
    revision: before.revision + 1,
    settings: WarningSettings.fromJson(
      (mutation.settings ?? before.settings).toJson(),
    ),
    records: records,
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
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
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
        },
      ),
    );
    return _db!;
  }

  Future<InventorySnapshot> _read(DatabaseExecutor db) async {
    final meta = (await db.query('meta', where: 'id=1')).single;
    final records = await db.query('medicines');
    final events = await db.query(
      'events',
      orderBy: 'revision DESC',
      limit: 200,
    );
    final receipts = await db.query('receipts');
    final totals = (await db.rawQuery(
      'SELECT COALESCE(SUM(sold_value),0) AS total, COALESCE(SUM(unknown_sold),0) AS missing FROM events WHERE undone=0',
    )).single;
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
      receipts: receipts.map((r) => r['request_id'] as String).toSet(),
      events: events
          .map(
            (r) => {
              ...jsonDecode(r['detail'] as String) as Map<String, dynamic>,
              'undone': r['undone'] == 1,
            },
          )
          .toList(),
      soldValue: totals['total'] as int,
      unknownSold: totals['missing'] as int,
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
