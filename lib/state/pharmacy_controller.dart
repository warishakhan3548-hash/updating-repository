import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/inventory_storage.dart';
import '../domain/ai_protocol.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/search.dart';
import '../domain/tracking.dart';
import '../services/search_worker.dart';

class PharmacyController extends ChangeNotifier {
  PharmacyController(
    this.storage, {
    DateTime Function()? clock,
    this.backgroundSearch = true,
  }) : clock = clock ?? DateTime.now;

  final InventoryStorage storage;
  final DateTime Function() clock;
  final bool backgroundSearch;
  InventorySnapshot snapshot = InventorySnapshot();
  bool ready = false;
  Future<void>? _load;
  Future<void> _writes = Future.value();
  bool _disposed = false;
  Timer? _midnight;
  SearchWorker? _searchWorker;

  WarningSettings get settings => snapshot.settings;
  DateTime get today => clock();
  List<Medicine> get records => snapshot.records.values.toList();
  List<SaleRecord> get sales => snapshot.sales;
  InventoryStats get stats => inventoryStats(records);
  bool get canUndo => snapshot.undoJournal.isNotEmpty;
  bool get canRedo => snapshot.redoJournal.isNotEmpty;

  Future<void> initialize() => _load ??= _initialize();

  Future<void> _initialize() async {
    try {
      snapshot = await storage.load();
      if (_disposed) return;
      if (backgroundSearch) {
        final worker = SearchWorker();
        _searchWorker = worker;
        await worker.replace(records);
        if (_disposed) {
          await worker.close();
          if (identical(_searchWorker, worker)) _searchWorker = null;
          return;
        }
      }
      ready = true;
      _scheduleMidnight();
      _emit();
    } catch (_) {
      if (!_disposed) rethrow;
    } finally {
      if (_disposed) await storage.close();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _midnight?.cancel();
    _midnight = null;
    final worker = _searchWorker;
    _searchWorker = null;
    if (worker != null) unawaited(worker.close());
    if (_load == null) unawaited(storage.close());
    super.dispose();
  }

  void _emit() {
    if (_disposed) return;
    notifyListeners();
    final worker = _searchWorker;
    if (worker != null) unawaited(worker.replace(records));
  }

  void refreshDay() {
    _scheduleMidnight();
    _emit();
  }

  void _scheduleMidnight() {
    _midnight?.cancel();
    if (_disposed) return;
    final now = clock();
    final next = DateTime(
      now.year,
      now.month,
      now.day + 1,
    ).add(const Duration(seconds: 1));
    _midnight = Timer(next.difference(now), refreshDay);
  }

  List<Medicine> list(SearchScope scope) =>
      records.where((m) => inScope(m, scope, settings, today)).toList()
        ..sort((a, b) => expiryOrder(a, b, today));

  List<Medicine> dispensingChoices(String id, {DateTime? on}) {
    final requested = snapshot.records[id];
    if (requested == null) return const [];
    return dispensingCandidates(records, requested, on ?? today);
  }

  Medicine? preferredDispensingStock(String id, {DateTime? on}) {
    final choices = dispensingChoices(id, on: on);
    return choices.isEmpty ? null : choices.first;
  }

  Future<void> _commit(InventoryMutation mutation) {
    final result = _writes.then((_) async {
      if (_disposed) throw StateError('App is closed.');
      snapshot = await storage.commit(mutation);
      _emit();
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> save(Medicine record, {required int expectedRevision}) async {
    final existing = snapshot.records[record.id];
    if (record.sold && existing?.sold != true && isExpiredOn(record, today)) {
      throw const FormatException(
        'Expired stock cannot be marked SOLD. Remove it with reason Expired so it stays in the correct safety history.',
      );
    }
    await _commit(
      InventoryMutation(
        expectedRevision: expectedRevision,
        label: existing == null
            ? 'Added ${record.name}'
            : 'Edited ${record.name}',
        upserts: [record],
      ),
    );
  }

  Future<void> setWarnings(WarningSettings value) => _commit(
    InventoryMutation(
      expectedRevision: snapshot.revision,
      label: 'Updated expiry warning windows',
      upserts: [],
      settings: value,
    ),
  );

  Future<void> markSold(String id) async {
    final m = snapshot.records[id];
    if (m == null || m.archived) throw StateError('This entry is unavailable.');
    if (m.sold) return;
    final now = clock();
    if (isExpiredOn(m, now)) {
      throw const FormatException(
        'Expired stock cannot be marked SOLD. Remove it with reason Expired instead.',
      );
    }
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Marked ${m.name} sold',
        upserts: [m.patch({'sold': true, 'quantity': 0})],
      ),
    );
  }

  Future<void> recordSale(
    String id, {
    required int quantity,
    int? totalAmountPaise,
    DateTime? occurredAt,
  }) async {
    final m = snapshot.records[id];
    if (m == null || m.archived) throw StateError('This entry is unavailable.');
    if (m.sold) throw const FormatException('This stock entry is already sold.');
    if (quantity <= 0) throw const FormatException('Sale quantity must be positive.');
    final available = m.quantity;
    if (available == null) {
      throw const FormatException('Set a known stock quantity before recording a sale.');
    }
    if (quantity > available) {
      throw FormatException('Only $available units are available in this stock entry.');
    }
    final at = occurredAt ?? clock();
    if (isExpiredOn(m, at)) {
      throw const FormatException('Expired stock cannot be recorded as a sale.');
    }
    if (m.manufacturingDate != null &&
        at.isBefore(DateTime(
          m.manufacturingDate!.year,
          m.manufacturingDate!.month,
          m.manufacturingDate!.day,
        ))) {
      throw const FormatException('Sale date cannot be before manufacturing date.');
    }
    final remaining = available - quantity;
    final sale = SaleRecord(
      id: '${at.microsecondsSinceEpoch}-$id',
      medicineId: id,
      medicineName: m.name,
      batch: m.batch,
      quantity: quantity,
      totalAmountPaise: totalAmountPaise,
      occurredAt: at,
    );
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Recorded sale of ${m.name}',
        upserts: [m.patch({'quantity': remaining, 'sold': remaining == 0})],
        salesToAdd: [sale],
      ),
    );
  }

  Future<void> archive(
    String id, {
    required RemovalReason reason,
    required int expectedRevision,
  }) async {
    final m = snapshot.records[id];
    if (m == null || m.archived) throw StateError('This entry is unavailable.');
    if (snapshot.revision != expectedRevision) {
      throw StateError('This stock changed. Reopen it before removing.');
    }
    await _commit(
      InventoryMutation(
        expectedRevision: expectedRevision,
        label: 'Removed ${m.name} · ${reason.label}',
        upserts: [
          m.patch({
            'archived': true,
            'removalReason': reason.name,
            'removedAt': clock().toIso8601String(),
          }),
        ],
      ),
    );
  }

  Future<void> archiveAll({required int expectedRevision}) async {
    if (snapshot.revision != expectedRevision) {
      throw StateError('Inventory changed. Review the database before removing all.');
    }
    final active = records.where((m) => !m.archived).toList();
    if (active.isEmpty) return;
    final at = clock().toIso8601String();
    await _commit(
      InventoryMutation(
        expectedRevision: expectedRevision,
        label: 'Removed all inventory (${active.length} entries)',
        upserts: [
          for (final m in active)
            m.patch({
              'archived': true,
              'removalReason': RemovalReason.correction.name,
              'removedAt': at,
            }),
        ],
      ),
    );
  }

  Future<void> undo() async {
    if (!canUndo) return;
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Undo',
        undo: true,
      ),
    );
  }

  Future<void> redo() async {
    if (!canRedo) return;
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Redo',
        redo: true,
      ),
    );
  }

  Future<List<SearchHit>> search(String query, SearchScope scope) async {
    final worker = _searchWorker;
    if (worker != null) {
      return worker.search(
        query,
        scope: scope,
        settings: settings,
        today: today,
      );
    }
    return searchRecords(records, query, scope, settings, today);
  }

  TrackingSummary tracking(TrackingRange range) =>
      trackingSummary(sales, range: range, today: today);

  Future<void> applyAiChanges(
    ReviewedAiResponse reviewed,
    Set<int> selected, {
    required int expectedRevision,
  }) async {
    final frozenSelection = Set<int>.unmodifiable(selected);
    final plan = await prepareAiMutation(
      snapshot,
      reviewed,
      frozenSelection,
      now: clock(),
    );
    if (snapshot.revision != expectedRevision) {
      throw StateError('Inventory changed while the AI plan was being reviewed. Review again.');
    }
    await _commit(
      InventoryMutation(
        expectedRevision: expectedRevision,
        label: reviewed.requestId.isEmpty
            ? 'Applied reviewed AI changes'
            : 'AI ${reviewed.requestId}',
        upserts: plan.upserts,
        requestId: reviewed.requestId,
      ),
    );
  }

  Future<void> restoreBackup(
    InventorySnapshot imported, {
    required int expectedRevision,
  }) async {
    final currentIds = snapshot.records.keys.toSet();
    final importedIds = imported.records.keys.toSet();
    final absent = currentIds.difference(importedIds);
    final at = clock().toIso8601String();
    final upserts = <Medicine>[
      ...imported.records.values,
      for (final id in absent)
        snapshot.records[id]!.patch({
          'archived': true,
          'removalReason': RemovalReason.correction.name,
          'removedAt': at,
        }),
    ];
    await _commit(
      InventoryMutation(
        expectedRevision: expectedRevision,
        label: 'Restored reviewed backup',
        upserts: upserts,
        replaceSales: imported.sales,
        settings: imported.settings,
      ),
    );
  }

  Future<void> restoreVersion(
    MedicineVersion version, {
    required int expectedRevision,
  }) async {
    await save(version.record, expectedRevision: expectedRevision);
  }
}
