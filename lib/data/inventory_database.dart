import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/automation_guard.dart';
import '../domain/sale_ledger_guard.dart';
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
    this.operationTime,
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
  final DateTime? operationTime;

  InventoryMutation withOperationTime(DateTime value) => InventoryMutation(
    expectedRevision: expectedRevision,
    label: label,
    upserts: upserts,
    upsertSales: upsertSales,
    removeIds: removeIds,
    removeSaleIds: removeSaleIds,
    settings: settings,
    requestId: requestId,
    undoEventId: undoEventId,
    undoable: undoable,
    soldValueOverride: soldValueOverride,
    unknownSoldOverride: unknownSoldOverride,
    operationTime: value,
  );
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
  final operationTime = mutation.operationTime;
  if (operationTime != null &&
      (operationTime.year < 2000 || operationTime.year > 2200)) {
    throw const FormatException('Invalid inventory operation time.');
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
      throw StateError(
        'One inventory transaction cannot repeat a $description ID.',
      );
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

// The latest Undo is intentionally rich for normal pharmacist actions, but a
// giant backup restore/bulk operation must never duplicate tens of thousands of
// OCR-heavy Medicine JSON objects into one in-memory + SQLite audit event. The
// audit row and transaction still commit; only the reversible before-image is
// omitted once either bound is crossed, making that event explicitly non-undoable.
const _maxUndoRows = 256;
const _maxUndoTextCharacters = 1000000;

int _medicineUndoTextWeight(Medicine record) =>
    512 +
    record.id.length +
    record.name.length +
    record.brand.length +
    record.manufacturer.length +
    record.salt.length +
    record.strength.length +
    record.form.length +
    record.barcode.length +
    record.batchNumber.length +
    record.block.length +
    record.row.length +
    record.vertical.length +
    record.location.length +
    record.notes.length +
    record.ocrText.length +
    record.archiveReason.length +
    (record.soldAt?.length ?? 0);

int _saleUndoTextWeight(SaleEvent sale) =>
    192 +
    sale.id.length +
    sale.stockId.length +
    sale.medicineName.length +
    sale.strength.length +
    sale.form.length +
    sale.salt.length;

bool _canCaptureUndoSnapshot(
  InventorySnapshot before,
  InventoryMutation mutation,
) {
  if (!mutation.undoable) return false;
  final recordIds = <String>{
    ...mutation.upserts.map((record) => record.id),
    ...mutation.removeIds,
  };
  final saleIds = <String>{
    ...mutation.upsertSales.map((sale) => sale.id),
    ...mutation.removeSaleIds,
  };
  if (recordIds.length + saleIds.length > _maxUndoRows) return false;

  var textWeight = 0;
  for (final id in recordIds) {
    final record = before.records[id];
    if (record == null) continue;
    textWeight += _medicineUndoTextWeight(record);
    if (textWeight > _maxUndoTextCharacters) return false;
  }
  for (final id in saleIds) {
    final sale = before.sales[id];
    if (sale == null) continue;
    textWeight += _saleUndoTextWeight(sale);
    if (textWeight > _maxUndoTextCharacters) return false;
  }
  return true;
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
  // One immutable operation timestamp drives both the durable audit event and
  // every date-sensitive persistence guard for this transaction. Controller
  // writes stamp this from the controller's injected business clock; direct
  // storage callers fall back to one wall-clock read here.
  final operationTime = mutation.operationTime ?? DateTime.now();
  final operationDay = civilDay(operationTime);
  final captureUndo = _canCaptureUndoSnapshot(before, mutation);
  return {
    'id': newId(),
    'revision': before.revision + 1,
    'label': mutation.label,
    'time': operationTime.toUtc().toIso8601String(),
    'businessDay': dateText(operationDay),
    'undoable': captureUndo,
    'undone': false,
    'before': captureUndo
        ? {
            for (final id in {
              ...mutation.upserts.map((m) => m.id),
              ...mutation.removeIds,
            })
              id: before.records[id]?.toJson(),
          }
        : <String, dynamic>{},
    'salesBefore': captureUndo
        ? {
            for (final id in {
              ...mutation.upsertSales.map((sale) => sale.id),
              ...mutation.removeSaleIds,
            })
              id: before.sales[id]?.toJson(),
          }
        : <String, dynamic>{},
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
  final eventTimeRaw = event['time'];
  if (eventTimeRaw is! String) {
    throw const FormatException('Inventory event time is missing.');
  }
  final operationTime = DateTime.tryParse(eventTimeRaw);
  if (operationTime == null ||
      operationTime.year < 2000 ||
      operationTime.year > 2200) {
    throw const FormatException('Inventory event time is invalid.');
  }
  // The audit instant is normalized to UTC for durable ordering, but the
  // pharmacist's business day must retain the controller/device local civil
  // date. Re-deriving the day from the UTC instant would shift transactions
  // around local midnight in positive/negative UTC offsets.
  final operationDayRaw = event['businessDay'];
  final parsedOperationDay = operationDayRaw is String
      ? DateTime.tryParse(operationDayRaw)
      : null;
  if (parsedOperationDay == null ||
      parsedOperationDay.year < 2000 ||
      parsedOperationDay.year > 2200 ||
      dateText(parsedOperationDay) != operationDayRaw) {
    throw const FormatException('Inventory business day is invalid.');
  }
  final operationDay = civilDay(parsedOperationDay);
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
      mutation.soldValueOverride != null ||
      mutation.unknownSoldOverride != null;
  if (mutation.undoEventId == null && !recoveryRestore) {
    ensureIntegritySafeInventoryMutation(
      before: before.records,
      after: records,
      touchedStockIds: {
        ...mutation.upserts.map((record) => record.id),
        ...mutation.removeIds,
      },
      today: operationDay,
    );
    ensureSafeSaleLedgerMutation(
      beforeRecords: before.records,
      afterRecords: records,
      beforeSales: before.sales,
      upsertSales: mutation.upsertSales,
      removeSaleIds: mutation.removeSaleIds,
    );
  }

  for (final sale in mutation.upsertSales) {
    sales[sale.id] = SaleEvent.fromJson(sale.toJson());
  }
  for (final id in mutation.removeSaleIds) {
    sales.remove(id);
  }
  // Validate aggregate money before committing, not while a statistics widget renders.
  InventoryStats(records.values, operationDay);
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

/// Converts one persisted Activity row into its safe runtime projection.
///
/// Audit history is useful but not authoritative stock. A single malformed
/// legacy `detail` JSON must therefore never make otherwise-valid medicines,
/// sales and settings impossible to open. SQL columns remain the witnesses for
/// event identity/revision/SOLD aggregates, and malformed rows are left on disk
/// untouched for forensic/manual recovery. Missing Undo payloads merely disable
/// Undo for that row instead of inventing a before-image.
Map<String, dynamic>? decodeStoredInventoryEvent(Map<String, Object?> row) {
  try {
    final rowId = row['id'];
    final rowRevision = row['revision'];
    final soldValue = row['sold_value'];
    final unknownSold = row['unknown_sold'];
    final undone = row['undone'];
    final raw = row['detail'];
    if (rowId is! String ||
        rowId.trim().isEmpty ||
        rowRevision is! int ||
        rowRevision < 1 ||
        soldValue is! int ||
        soldValue < 0 ||
        unknownSold is! int ||
        unknownSold < 0 ||
        undone is! int ||
        (undone != 0 && undone != 1) ||
        raw is! String) {
      return null;
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final event = Map<String, dynamic>.from(decoded);
    final label = event['label'];
    final timeRaw = event['time'];
    final time = timeRaw is String ? DateTime.tryParse(timeRaw) : null;
    if (event['id'] != rowId ||
        event['revision'] != rowRevision ||
        label is! String ||
        label.trim().isEmpty ||
        label.length > 1200 ||
        time == null ||
        time.year < 2000 ||
        time.year > 2200) {
      return null;
    }

    final beforeRaw = event['before'];
    final salesBeforeRaw = event['salesBefore'];
    final settingsBeforeRaw = event['settingsBefore'];
    final canUndo =
        event['undoable'] == true &&
        beforeRaw is Map &&
        settingsBeforeRaw is Map;

    return <String, dynamic>{
      ...event,
      'soldValue': soldValue,
      'unknownSold': unknownSold,
      'undoable': canUndo,
      'undone': undone == 1,
      'before': beforeRaw is Map
          ? Map<String, dynamic>.from(beforeRaw)
          : <String, dynamic>{},
      'salesBefore': salesBeforeRaw is Map
          ? Map<String, dynamic>.from(salesBeforeRaw)
          : <String, dynamic>{},
      if (settingsBeforeRaw is Map)
        'settingsBefore': Map<String, dynamic>.from(settingsBeforeRaw),
    };
  } catch (_) {
    return null;
  }
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
    final eventRows = await db.query(
      'events',
      orderBy: 'revision DESC',
      limit: 200,
    );
    final receipts = await db.query('receipts');
    final events = <Map<String, dynamic>>[];
    for (final row in eventRows) {
      final event = decodeStoredInventoryEvent(row);
      if (event != null) events.add(event);
    }
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
      events: events,
      soldValue: meta['sold_value'] as int,
      unknownSold: meta['unknown_sold'] as int,
    );
  }

  @override
  Future<InventorySnapshot> load() async {
    final db = await _open();
    // Metadata, medicines, sales and receipts describe one revision. Reading
    // them in separate autocommit statements can mix revisions if another
    // connection commits between queries (startup/restore/recovery).
    final snapshot = await db.transaction((tx) => _read(tx));
    _cached = snapshot;
    return snapshot;
  }
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
      var batch = tx.batch();
      var queued = 0;
      Future<void> flushBatch() async {
        if (queued == 0) return;
        await batch.commit(noResult: true);
        batch = tx.batch();
        queued = 0;
      }

      Future<void> queuedOperation() async {
        queued++;
        if (queued >= 500) await flushBatch();
      }

      for (final m in mutation.upserts) {
        // Validate every row before it is queued. Chunked batches keep a
        // full-phone restore inside one SQLite transaction without either one
        // platform round-trip per row or one unbounded in-memory Batch.
        final valid = Medicine.fromJson(m.toJson());
        batch.insert(
          'medicines',
          {'id': valid.id, 'facts': jsonEncode(valid.toJson())},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await queuedOperation();
      }
      for (final id in mutation.removeIds) {
        batch.delete('medicines', where: 'id=?', whereArgs: [id]);
        await queuedOperation();
      }
      for (final sale in mutation.upsertSales) {
        final valid = SaleEvent.fromJson(sale.toJson());
        batch.insert(
          'sales',
          {'id': valid.id, 'facts': jsonEncode(valid.toJson())},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await queuedOperation();
      }
      for (final id in mutation.removeSaleIds) {
        batch.delete('sales', where: 'id=?', whereArgs: [id]);
        await queuedOperation();
      }
      await flushBatch();
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
