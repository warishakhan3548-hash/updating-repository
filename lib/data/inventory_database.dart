import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/medicine.dart';

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
    if (m.sold && before.records[m.id]?.sold != true) {
      if (m.soldQuantity != null && m.soldUnitPricePaise != null) {
        soldValue += m.soldQuantity! * m.soldUnitPricePaise!;
      } else {
        unknownSold++;
      }
    }
  }
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

class SqliteInventoryStorage implements InventoryStorage {
  SqliteInventoryStorage({this.path, this.factory});
  final String? path;
  final DatabaseFactory? factory;
  Database? _db;
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
  Future<InventorySnapshot> load() async => _read(await _open());
  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) async {
    final db = await _open();
    return db.transaction((tx) async {
      final before = await _read(tx);
      if (before.revision != mutation.expectedRevision)
        throw StateError(
          'Inventory changed. Reopen this review before saving.',
        );
      if (mutation.requestId != null &&
          before.receipts.contains(mutation.requestId))
        throw StateError('This AI request has already been applied.');
      final event = makeEvent(before, mutation);
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
      return _read(tx);
    });
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
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
    final records = {..._state.records};
    for (final m in mutation.upserts) {
      records[m.id] = Medicine.fromJson(m.toJson());
    }
    for (final id in mutation.removeIds) {
      records.remove(id);
    }
    final events = [
      event,
      ..._state.events.map(
        (e) => e['id'] == mutation.undoEventId ? {...e, 'undone': true} : e,
      ),
    ];
    var soldValue = 0, unknown = 0;
    for (final e in events.where((e) => e['undone'] != true)) {
      soldValue += e['soldValue'] as int;
      unknown += e['unknownSold'] as int;
    }
    _state = InventorySnapshot(
      revision: _state.revision + 1,
      settings: mutation.settings ?? _state.settings,
      records: records,
      events: events,
      receipts: {
        ..._state.receipts,
        if (mutation.requestId != null) mutation.requestId!,
      },
      soldValue: soldValue,
      unknownSold: unknown,
    );
    return _state;
  }

  @override
  Future<void> close() async {}
}
