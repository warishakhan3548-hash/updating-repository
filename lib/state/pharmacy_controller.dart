import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/inventory_database.dart';
import '../domain/ai_protocol.dart';
import '../domain/backup.dart';
import '../domain/dispensing_plan.dart';
import '../domain/home_projection.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/sales_overview.dart';
import '../domain/search.dart';
import '../domain/tracking.dart';
import '../services/search_worker.dart';
import '../domain/supplier.dart';
import '../domain/supplier_return.dart';

const _maxStockQuantity = 100000000;

/// Returns the next civil-day refresh instant in the same time basis as [now].
///
/// Production uses a local wall clock, while deterministic tests and embedders
/// may inject UTC. Mixing a UTC clock with a local DateTime constructor can
/// produce a zero/negative timer delay on non-UTC devices and repeatedly wake
/// the controller instead of waiting for the next business day.
@visibleForTesting
DateTime nextInventoryDayRefreshInstant(DateTime now) {
  final nextMidnight = now.isUtc
      ? DateTime.utc(now.year, now.month, now.day + 1)
      : DateTime(now.year, now.month, now.day + 1);
  return nextMidnight.add(const Duration(seconds: 1));
}

enum StockAdjustmentKind { setExact, receive }

class ReviewedStockAdjustment {
  const ReviewedStockAdjustment({
    required this.baseRevision,
    required this.stockId,
    required this.recordRevision,
    required this.kind,
    required this.requestedQuantity,
    required this.beforeQuantity,
    required this.afterQuantity,
    required this.wasSold,
  });

  final int baseRevision;
  final String stockId;
  final int recordRevision;
  final StockAdjustmentKind kind;
  final int requestedQuantity;
  final int? beforeQuantity;
  final int afterQuantity;
  final bool wasSold;

  bool get changesQuantity => beforeQuantity != afterQuantity;
}

class ReviewedArchive {
  const ReviewedArchive({
    required this.baseRevision,
    required this.record,
    required this.reason,
  });

  final int baseRevision;
  final Medicine record;
  final String reason;
  String get stockId => record.id;
}

class ReviewedMarkSold {
  const ReviewedMarkSold({required this.baseRevision, required this.record});

  final int baseRevision;
  final Medicine record;
  String get stockId => record.id;
}

/// Immutable token binding an Undo confirmation to the exact latest audit
/// event the owner reviewed. Undo is intentionally global: any newer commit
/// changes what "latest" means, so a stale token must fail closed.
class ReviewedUndo {
  const ReviewedUndo({
    required this.baseRevision,
    required this.eventId,
    required this.eventRevision,
    required this.label,
  });

  final int baseRevision;
  final String eventId;
  final int eventRevision;
  final String label;
}

/// Immutable single-stock sale review.
///
/// The token binds the pharmacist's confirmation to the exact physical stock
/// row and exact sale facts they reviewed. Unrelated database traffic may advance
/// the global inventory revision, but any change to this row fails closed.
class ReviewedSale {
  const ReviewedSale({
    required this.baseRevision,
    required this.record,
    required this.quantity,
    required this.totalAmountPaise,
    required this.occurredAt,
    required this.markSoldOut,
  });

  final int baseRevision;
  final Medicine record;
  final int quantity;
  final int? totalAmountPaise;
  final DateTime occurredAt;
  final bool markSoldOut;

  String get stockId => record.id;
}

bool _sameReviewedMedicine(Medicine live, Medicine reviewed) =>
    mapEquals(live.toJson(), reviewed.toJson());

bool _sameStatsMedicineProjection(Medicine before, Medicine after) {
  if (before.archived != after.archived) return false;
  if (before.archived) return true;
  if (before.identity != after.identity ||
      normalize(before.name) != normalize(after.name) ||
      before.salt.isEmpty != after.salt.isEmpty ||
      normalize(before.salt) != normalize(after.salt) ||
      before.unitPricePaise != after.unitPricePaise ||
      before.sold != after.sold) {
    return false;
  }
  if (before.sold) return true;
  return before.form == after.form &&
      before.quantity == after.quantity &&
      before.expiry == after.expiry;
}

bool _sameSalesOverviewMedicineProjection(Medicine before, Medicine after) {
  if (before.sold != after.sold) return false;
  if (!before.sold) return true;
  return before.name == after.name &&
      before.soldQuantity == after.soldQuantity &&
      before.soldAt == after.soldAt &&
      before.soldUnitPricePaise == after.soldUnitPricePaise &&
      before.unitPricePaise == after.unitPricePaise;
}

SaleEvent? _knownSoldDepletion(
  Medicine medicine, {
  required int? quantity,
  required DateTime occurredAt,
  required int? unitPricePaise,
}) {
  if (quantity == null || quantity <= 0) return null;
  return SaleEvent(
    id: newId(),
    stockId: medicine.id,
    medicineName: medicine.name,
    strength: medicine.strength,
    form: medicine.form,
    salt: medicine.salt,
    quantity: quantity,
    occurredAt: occurredAt,
    savedUnitPricePaise: unitPricePaise,
  );
}

class BulkArchiveReview {
  BulkArchiveReview({
    required this.baseRevision,
    required Iterable<String> activeIds,
  }) : activeIds = Set.unmodifiable(activeIds);

  final int baseRevision;
  final Set<String> activeIds;
  int get activeCount => activeIds.length;
}

/// Immutable recovery token captured before the owner confirms a removed-stock
/// restore. The exact inventory revision and row revision are revalidated at
/// commit time so a stale dialog can never restore a different record state.
class ReviewedArchivedRestore {
  const ReviewedArchivedRestore({
    required this.baseRevision,
    required this.stockId,
    required this.recordRevision,
    required this.archiveReason,
    required this.archivedAt,
  });

  final int baseRevision;
  final String stockId;
  final int recordRevision;
  final String archiveReason;
  final DateTime? archivedAt;
}

bool _equivalentReviewedFefoPlan(
  FefoDispensingPlan reviewed,
  FefoDispensingPlan fresh,
) {
  if (reviewed.productKey != fresh.productKey ||
      reviewed.requestedQuantity != fresh.requestedQuantity ||
      reviewed.plannedQuantity != fresh.plannedQuantity ||
      !listEquals(
        reviewed.unknownQuantityStockIds,
        fresh.unknownQuantityStockIds,
      ) ||
      reviewed.allocations.length != fresh.allocations.length) {
    return false;
  }
  for (var i = 0; i < reviewed.allocations.length; i++) {
    final before = reviewed.allocations[i];
    final after = fresh.allocations[i];
    if (before.stockId != after.stockId ||
        before.quantity != after.quantity ||
        before.availableQuantity != after.availableQuantity ||
        before.batchNumber != after.batchNumber ||
        before.address != after.address ||
        before.expiry != after.expiry ||
        before.expiryMonthOnly != after.expiryMonthOnly) {
      return false;
    }
  }
  return true;
}

class PharmacyController extends ChangeNotifier {
  PharmacyController(
    this.storage, {
    DateTime Function()? clock,
    this.backgroundSearch = true,
  }) : clock = clock ?? DateTime.now;
  final InventoryStorage storage;
  final bool backgroundSearch;
  final DateTime Function() clock;
  InventorySnapshot snapshot = InventorySnapshot();
  bool ready = false, _disposed = false, aiPreparing = false;
  int preparedActions = 0;
  bool _cancelAi = false;
  Timer? _midnight;
  Future<void>? _initializing;
  Future<void> _writes = Future.value();
  // Active and Removed Stock search projections advance independently. Keep
  // their lazy isolate sessions independent too; otherwise switching surfaces
  // makes one projection's revision invalidate the other's cached dataset and
  // fuzzy index even when none of its own searchable rows changed.
  final _searchWorker = SearchWorker();
  final _archivedSearchWorker = SearchWorker();
  MedicineSearch? _webSearch, _webArchivedSearch;
  int _webSearchDatasetEpoch = -1, _webArchivedSearchDatasetEpoch = -1;
  int _webSearchIndexBuilds = 0, _webArchivedSearchIndexBuilds = 0;

  // Read models are derived from one immutable InventorySnapshot. Keep exactly
  // one stable record-reference list and memoized projections per snapshot so
  // keystrokes and non-inventory notifications do not repeatedly allocate or
  // rescan a large pharmacy. Snapshot identity, not just its numeric revision,
  // is the cache witness; a reload with the same revision therefore cannot reuse
  // stale derived state. Day-sensitive projections carry their own civil-day key.
  InventorySnapshot? _readSnapshot;
  List<Medicine>? _readRecords;
  InventoryStats? _statsCache;
  String _statsDayKey = '';
  int _statsProjectionEpoch = 0;
  HomeInventoryProjection? _homeProjectionCache;
  String _homeProjectionDayKey = '';
  int _homeProjectionEpoch = 0, _homeProjectionCacheEpoch = -1;
  SalesOverview? _salesOverviewCache;
  int _salesOverviewEpoch = 0;
  final Map<String, TrackingStats> _trackingCache = <String, TrackingStats>{};
  String _trackingDayKey = '';
  List<SupplierReturnCandidate>? _supplierReturnsCache;
  String _supplierReturnsDayKey = '';
  int _searchDatasetEpoch = 0;
  int _archivedSearchDatasetEpoch = 0;
  String _publishedDayKey = '';

  DateTime get today => civilDay(clock());
  WarningSettings get settings => snapshot.settings;
  Iterable<Medicine> get records => snapshot.records.values;
  Iterable<Supplier> get suppliers => snapshot.suppliers.values;
  Iterable<SaleEvent> get sales => snapshot.sales.values;

  Supplier? supplierForStock(Medicine medicine) =>
      medicine.supplierId.isEmpty ? null : snapshot.suppliers[medicine.supplierId];

  bool _salesOverviewEventRelevant(Map<String, dynamic> event) {
    if (event['undone'] == true) return false;
    final soldValue = event['soldValue'];
    final unknownSold = event['unknownSold'];
    return (soldValue is int && soldValue > 0) ||
        (unknownSold is int && unknownSold > 0);
  }

  bool _sameSalesOverviewEventProjection(
    List<Map<String, dynamic>> before,
    List<Map<String, dynamic>> after,
  ) {
    final beforeEvents = before.where(_salesOverviewEventRelevant).iterator;
    final afterEvents = after.where(_salesOverviewEventRelevant).iterator;
    while (true) {
      final beforeHasNext = beforeEvents.moveNext();
      final afterHasNext = afterEvents.moveNext();
      if (beforeHasNext != afterHasNext) return false;
      if (!beforeHasNext) return true;
      if (!identical(beforeEvents.current, afterEvents.current)) return false;
    }
  }

  void _syncReadSnapshot() {
    if (identical(_readSnapshot, snapshot)) return;
    final previous = _readSnapshot;
    final recordsChanged =
        previous == null || !identical(previous.records, snapshot.records);
    final settingsChanged =
        previous == null || !identical(previous.settings, snapshot.settings);
    final suppliersChanged =
        previous == null || !identical(previous.suppliers, snapshot.suppliers);
    final salesChanged =
        previous == null || !identical(previous.sales, snapshot.sales);
    final salesOverviewEventsChanged =
        previous == null ||
        !_sameSalesOverviewEventProjection(previous.events, snapshot.events);
    _readSnapshot = snapshot;

    // InventorySnapshot uses copy-on-write collections. Reuse every derived
    // read model until one of its actual immutable inputs changes. This keeps a
    // supplier edit, warning preference or sale-history write from forcing the
    // next unrelated screen to rescan the complete pharmacy.
    if (recordsChanged || _readRecords == null) {
      _readRecords = List<Medicine>.unmodifiable(snapshot.records.values);
    }

    if (settingsChanged) {
      _homeProjectionCache = null;
      _homeProjectionDayKey = '';
    }
    if (salesChanged || salesOverviewEventsChanged) {
      _salesOverviewCache = null;
      _salesOverviewEpoch++;
    }
    if (recordsChanged || salesChanged) {
      _trackingCache.clear();
      _trackingDayKey = '';
    }
    if (recordsChanged || suppliersChanged) {
      _supplierReturnsCache = null;
      _supplierReturnsDayKey = '';
    }
  }

  /// Monotonic token for the exact medicine facts consumed by local search,
  /// scoped browse membership and result ordering.
  ///
  /// Stock counters such as quantity and price deliberately do not advance this
  /// token. Search surfaces can therefore repaint live card values without
  /// re-running the same fuzzy query or browse sort.
  int get searchProjectionEpoch {
    _syncReadSnapshot();
    return _searchDatasetEpoch;
  }

  @visibleForTesting
  int get debugSearchDatasetEpoch => searchProjectionEpoch;

  /// Monotonic token for the exact medicine facts consumed by [stats].
  ///
  /// Notes, shelf location, barcode and other operational metadata do not
  /// advance this token, so the snapshot dashboard can stay frame-quiet while
  /// those unrelated fields are edited.
  int get statsProjectionEpoch => _statsProjectionEpoch;

  /// Monotonic token for search and ordering facts of removed stock only.
  ///
  /// Active-stock edits, sales, suppliers and warning preferences cannot change
  /// Removed Stock results, so that screen can stay idle for those publications.
  int get archivedSearchProjectionEpoch {
    _syncReadSnapshot();
    return _archivedSearchDatasetEpoch;
  }

  @visibleForTesting
  int get debugWebSearchIndexBuilds => _webSearchIndexBuilds;

  @visibleForTesting
  int get debugWebArchivedSearchIndexBuilds => _webArchivedSearchIndexBuilds;

  /// Monotonic version for the exact medicine/settings inputs consumed by
  /// [homeProjection]. The civil day remains a separate token because expiry
  /// status changes at midnight without any inventory write.
  int get homeProjectionEpoch {
    _syncReadSnapshot();
    return _homeProjectionEpoch;
  }

  /// Monotonic version for the exact inputs consumed by [salesOverview].
  ///
  /// Activity is a bounded audit stream and changes on every saved mutation.
  /// Only SOLD-affecting activity participates in sales analytics, so screens
  /// can use this epoch without repainting for supplier/settings-only writes.
  int get salesOverviewEpoch {
    _syncReadSnapshot();
    return _salesOverviewEpoch;
  }

  List<Medicine> get _stableRecords {
    _syncReadSnapshot();
    return _readRecords!;
  }

  InventoryStats get stats {
    final date = today;
    final dayKey = dateText(date);
    _syncReadSnapshot();
    if (_statsCache == null || _statsDayKey != dayKey) {
      _statsCache = InventoryStats(_stableRecords, date);
      _statsDayKey = dayKey;
    }
    return _statsCache!;
  }

  HomeInventoryProjection get homeProjection {
    final date = today;
    final dayKey = dateText(date);
    _syncReadSnapshot();
    if (_homeProjectionCache == null ||
        _homeProjectionDayKey != dayKey ||
        _homeProjectionCacheEpoch != _homeProjectionEpoch) {
      _homeProjectionCache = HomeInventoryProjection.build(
        medicines: _stableRecords,
        settings: settings,
        today: date,
      );
      _homeProjectionDayKey = dayKey;
      _homeProjectionCacheEpoch = _homeProjectionEpoch;
    }
    return _homeProjectionCache!;
  }

  SalesOverview get salesOverview {
    _syncReadSnapshot();
    return _salesOverviewCache ??= SalesOverview(
      snapshot.sales.values,
      medicines: _stableRecords,
      events: snapshot.events,
    );
  }

  TrackingStats tracking(TrackingRange range) {
    final date = today;
    final dayKey = dateText(date);
    _syncReadSnapshot();
    if (_trackingDayKey != dayKey) {
      _trackingCache.clear();
      _trackingDayKey = dayKey;
    }

    // Tracking is an expensive read model: it walks current stock, sale history,
    // daily demand and reorder projections. Screens often ask for the same range
    // more than once while building related guidance. Reuse only within the
    // exact immutable inventory snapshot + civil day + requested range.
    final key =
        '${range.start.microsecondsSinceEpoch}:${range.end.microsecondsSinceEpoch}';
    final cached = _trackingCache[key];
    if (cached != null) return cached;

    // Custom date pickers can produce many distinct ranges over one session.
    // Keep this a small read-through cache rather than another source of truth.
    if (_trackingCache.length >= 8) {
      _trackingCache.remove(_trackingCache.keys.first);
    }
    final result = TrackingStats(
      medicines: _stableRecords,
      sales: sales,
      range: range,
      today: date,
      suppliers: snapshot.suppliers,
    );
    _trackingCache[key] = result;
    return result;
  }

  Future<void> initialize() {
    if (_disposed) return Future.error(StateError('App is closed.'));
    final running = _initializing;
    if (running != null) return running;
    late final Future<void> operation;
    operation = _load().whenComplete(() {
      if (identical(_initializing, operation)) _initializing = null;
    });
    _initializing = operation;
    return operation;
  }

  Future<void> _load() async {
    final loaded = await storage.load();
    if (_disposed) return;
    snapshot = loaded;
    _statsCache = null;
    _statsDayKey = '';
    _salesOverviewCache = null;
    _statsProjectionEpoch++;
    _salesOverviewEpoch++;
    _searchDatasetEpoch++;
    _archivedSearchDatasetEpoch++;
    _homeProjectionEpoch++;
    ready = true;
    _scheduleMidnight();
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    _publishedDayKey = dateText(today);
    notifyListeners();
  }

  void refreshDay() {
    _scheduleMidnight();
    if (_publishedDayKey == dateText(today)) return;
    _emit();
  }

  void _scheduleMidnight() {
    _midnight?.cancel();
    if (_disposed) return;
    final now = clock();
    final next = nextInventoryDayRefreshInstant(now);
    _midnight = Timer(next.difference(now), refreshDay);
  }

  List<Medicine> list(SearchScope scope) {
    final selectedSettings = settings;
    final date = today;
    final result = records
        .where((medicine) => inScope(medicine, scope, selectedSettings, date))
        .toList();
    result.sort((a, b) => expiryOrder(a, b, date));
    return result;
  }

  List<Medicine> dispensingChoices(String id, {DateTime? on}) {
    final requested = snapshot.records[id];
    if (requested == null) return const [];
    return dispensingCandidates(records, requested, on ?? today);
  }

  Medicine? preferredDispensingStock(String id, {DateTime? on}) {
    final choices = dispensingChoices(id, on: on);
    return choices.isEmpty ? null : choices.first;
  }

  ReviewedFefoSale reviewFefoSale(
    String id, {
    required int quantity,
    DateTime? occurredAt,
  }) {
    final anchor = snapshot.records[id];
    if (anchor == null || anchor.archived || anchor.sold) {
      throw StateError(
        'Choose an active stock entry before recording a FEFO sale.',
      );
    }
    final time = occurredAt ?? clock();
    if (civilDay(time).isAfter(today)) {
      throw const FormatException('A sale cannot be recorded in the future.');
    }
    final plan = planFefoDispensing(
      records: records,
      requested: anchor,
      quantity: quantity,
      date: time,
    );
    return ReviewedFefoSale(
      baseRevision: snapshot.revision,
      occurredAt: time,
      plan: plan,
      stockRevisions: Map.unmodifiable(<String, int>{
        for (final allocation in plan.allocations)
          allocation.stockId: snapshot.records[allocation.stockId]!.revision,
      }),
    );
  }

  Future<void> applyFefoSale(ReviewedFefoSale review) async {
    final reviewedPlan = review.plan;
    if (!reviewedPlan.complete || reviewedPlan.allocations.isEmpty) {
      throw StateError(
        'This FEFO sale is incomplete and cannot be saved automatically.',
      );
    }
    await _queueReviewedCommit((_) {
      var safeReview = review;
      if (review.baseRevision != snapshot.revision) {
        if (review.stockRevisions.length != reviewedPlan.allocations.length) {
          throw StateError(
            'This FEFO review cannot be safely rebased. Review the sale again before saving.',
          );
        }
        for (final allocation in reviewedPlan.allocations) {
          final live = snapshot.records[allocation.stockId];
          if (live == null ||
              live.revision != review.stockRevisions[allocation.stockId]) {
            throw StateError(
              'A reviewed FEFO batch changed after confirmation was prepared. Review the sale again before saving.',
            );
          }
        }
        final anchor = snapshot.records[reviewedPlan.allocations.first.stockId];
        if (anchor == null ||
            anchor.archived ||
            anchor.sold ||
            anchor.identity != reviewedPlan.productKey) {
          throw StateError(
            'A reviewed FEFO batch is no longer available. Review the sale again.',
          );
        }
        final fresh = reviewFefoSale(
          anchor.id,
          quantity: reviewedPlan.requestedQuantity,
          occurredAt: review.occurredAt,
        );
        if (!_equivalentReviewedFefoPlan(reviewedPlan, fresh.plan)) {
          throw StateError(
            'FEFO priority changed after this sale was reviewed. Review the live batch allocation again before saving.',
          );
        }
        safeReview = fresh;
      }

      final plan = safeReview.plan;
      final updates = <Medicine>[];
      final saleEvents = <SaleEvent>[];
      for (final allocation in plan.allocations) {
        final live = snapshot.records[allocation.stockId];
        if (live == null || live.archived || live.sold) {
          throw StateError(
            'A reviewed FEFO batch is no longer available. Review the sale again.',
          );
        }
        if (live.identity != plan.productKey) {
          throw StateError(
            'A reviewed FEFO batch no longer matches the medicine identity.',
          );
        }
        validateDispensingDate(live, safeReview.occurredAt);
        final available = live.quantity;
        if (available == null || available != allocation.availableQuantity) {
          throw StateError(
            'A reviewed FEFO batch quantity changed or became unknown. Review again.',
          );
        }
        if (allocation.quantity < 1 || allocation.quantity > available) {
          throw StateError('The reviewed FEFO allocation is no longer valid.');
        }
        final remaining = available - allocation.quantity;
        final soldOut = remaining == 0;
        updates.add(
          live.patch({
            'quantity': remaining,
            if (soldOut) ...{
              'sold': true,
              'soldAt': safeReview.occurredAt.toIso8601String(),
              'soldQuantity': available,
              'soldUnitPricePaise': live.unitPricePaise,
            },
          }),
        );
        saleEvents.add(
          SaleEvent(
            id: newId(),
            stockId: live.id,
            medicineName: live.name,
            strength: live.strength,
            form: live.form,
            salt: live.salt,
            quantity: allocation.quantity,
            occurredAt: safeReview.occurredAt,
            savedUnitPricePaise: live.unitPricePaise,
          ),
        );
      }
      return InventoryMutation(
        expectedRevision: safeReview.baseRevision,
        label:
            'FEFO sale · ${plan.title} · ${plan.requestedQuantity} units · ${plan.allocations.length} ${plan.allocations.length == 1 ? 'batch' : 'batches'}',
        upserts: updates,
        upsertSales: saleEvents,
      );
    });
  }

  bool _mutationChangesSearchProjection(
    InventorySnapshot before,
    InventorySnapshot after,
    InventoryMutation mutation,
  ) {
    bool changed(String id) {
      final previous = before.records[id];
      final current = after.records[id];
      if (previous == null || current == null) return previous != current;
      return !sameSearchProjection(previous, current);
    }

    for (final record in mutation.upserts) {
      if (changed(record.id)) return true;
    }
    for (final id in mutation.removeIds) {
      if (changed(id)) return true;
    }
    return false;
  }

  bool _mutationChangesArchivedSearchProjection(
    InventorySnapshot before,
    InventorySnapshot after,
    InventoryMutation mutation,
  ) {
    bool changed(String id) {
      final previous = before.records[id];
      final current = after.records[id];
      final previousArchived = previous?.archived ?? false;
      final currentArchived = current?.archived ?? false;
      if (!previousArchived && !currentArchived) return false;
      if (previous == null || current == null) return previous != current;
      return !sameSearchProjection(previous, current);
    }

    for (final record in mutation.upserts) {
      if (changed(record.id)) return true;
    }
    for (final id in mutation.removeIds) {
      if (changed(id)) return true;
    }
    return false;
  }

  bool _mutationChangesStatsProjection(
    InventorySnapshot before,
    InventorySnapshot after,
    InventoryMutation mutation,
  ) {
    bool changed(String id) {
      final previous = before.records[id];
      final current = after.records[id];
      if (previous == null || current == null) return previous != current;
      return !_sameStatsMedicineProjection(previous, current);
    }

    for (final record in mutation.upserts) {
      if (changed(record.id)) return true;
    }
    for (final id in mutation.removeIds) {
      if (changed(id)) return true;
    }
    return false;
  }

  bool _mutationChangesSalesOverviewMedicineProjection(
    InventorySnapshot before,
    InventorySnapshot after,
    InventoryMutation mutation,
  ) {
    bool changed(String id) {
      final previous = before.records[id];
      final current = after.records[id];
      if (previous == null || current == null) {
        return (previous?.sold ?? false) || (current?.sold ?? false);
      }
      return !_sameSalesOverviewMedicineProjection(previous, current);
    }

    for (final record in mutation.upserts) {
      if (changed(record.id)) return true;
    }
    for (final id in mutation.removeIds) {
      if (changed(id)) return true;
    }
    return false;
  }

  bool _mutationChangesHomeProjection(
    InventorySnapshot before,
    InventorySnapshot after,
    InventoryMutation mutation,
  ) {
    if (before.settings.shortDays != after.settings.shortDays ||
        before.settings.months != after.settings.months) {
      return true;
    }

    bool changed(String id) {
      final previous = before.records[id];
      final current = after.records[id];
      if (previous == null || current == null) return previous != current;
      return !sameHomeProjectionInput(previous, current);
    }

    for (final record in mutation.upserts) {
      if (changed(record.id)) return true;
    }
    for (final id in mutation.removeIds) {
      if (changed(id)) return true;
    }
    return false;
  }

  Future<void> _queueCommit(InventoryMutation? Function() buildMutation) {
    final result = _writes.then((_) async {
      if (_disposed) throw StateError('App is closed.');
      final mutation = buildMutation();
      if (mutation == null) return;
      final before = snapshot;
      final committed = await storage.commit(mutation);
      if (_mutationChangesSearchProjection(before, committed, mutation)) {
        _searchDatasetEpoch++;
      }
      if (_mutationChangesArchivedSearchProjection(
        before,
        committed,
        mutation,
      )) {
        _archivedSearchDatasetEpoch++;
      }
      if (_mutationChangesHomeProjection(before, committed, mutation)) {
        _homeProjectionEpoch++;
      }
      if (_mutationChangesStatsProjection(before, committed, mutation)) {
        _statsCache = null;
        _statsDayKey = '';
        _statsProjectionEpoch++;
      }
      if (_mutationChangesSalesOverviewMedicineProjection(
        before,
        committed,
        mutation,
      )) {
        _salesOverviewCache = null;
        _salesOverviewEpoch++;
      }
      snapshot = committed;
      _emit();
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _queueReviewedCommit(
    InventoryMutation? Function(DateTime operationTime) buildMutation,
  ) => _queueCommit(() {
    final operationTime = clock();
    final mutation = buildMutation(operationTime);
    return mutation?.withOperationTime(operationTime);
  });

  Future<void> _commit(InventoryMutation mutation, {DateTime? operationTime}) {
    final committedMutation = mutation.withOperationTime(
      operationTime ?? clock(),
    );
    return _queueCommit(() => committedMutation);
  }

  Future<void> commitReviewedRecordUpdate({
    required String stockId,
    required int recordRevision,
    required String Function(Medicine live) label,
    required Medicine? Function(Medicine live, DateTime operationTime) update,
  }) => _queueReviewedCommit((operationTime) {
    final live = snapshot.records[stockId];
    if (live == null || live.revision != recordRevision) {
      throw StateError(
        'The reviewed stock entry changed or is no longer available. Review the action again.',
      );
    }
    final updated = update(live, operationTime);
    if (updated == null) return null;
    if (updated.id != live.id) {
      throw StateError('A reviewed update cannot replace a different stock ID.');
    }
    return InventoryMutation(
      expectedRevision: snapshot.revision,
      label: label(live),
      upserts: <Medicine>[updated],
    );
  });

  Future<void> saveSupplier(
    Supplier supplier, {
    required int expectedRevision,
  }) {
    if (expectedRevision != snapshot.revision) {
      return Future<void>.error(
        StateError(
          'Inventory changed. Reopen this supplier before saving.',
        ),
      );
    }

    final reviewed = snapshot.suppliers[supplier.id];
    final reviewedRevision = reviewed?.revision;
    if (reviewedRevision != null &&
        supplier.revision != reviewedRevision + 1) {
      return Future<void>.error(
        StateError(
          'This supplier changed while it was being edited. Reopen the live supplier before saving.',
        ),
      );
    }

    // Bind the edit to this supplier row, not to unrelated pharmacy traffic.
    // The serialized turn may safely rebase its global CAS if this exact
    // supplier revision is still unchanged.
    return _queueReviewedCommit((_) {
      final live = snapshot.suppliers[supplier.id];
      final sameReviewedRow = reviewedRevision == null
          ? live == null
          : live != null && live.revision == reviewedRevision;
      if (!sameReviewedRow) {
        throw StateError(
          'This supplier changed while it was being edited. Reopen the live supplier before saving.',
        );
      }
      return InventoryMutation(
        expectedRevision: snapshot.revision,
        label: live == null
            ? 'Added supplier · ${supplier.name}'
            : 'Updated supplier · ${supplier.name}',
        upserts: const <Medicine>[],
        upsertSuppliers: <Supplier>[supplier],
      );
    });
  }

  List<SupplierReturnCandidate> get supplierReturns {
    final date = today;
    final dayKey = dateText(date);
    _syncReadSnapshot();
    if (_supplierReturnsCache == null || _supplierReturnsDayKey != dayKey) {
      _supplierReturnsCache = supplierReturnCandidates(
        medicines: _stableRecords,
        suppliers: snapshot.suppliers,
        today: date,
      );
      _supplierReturnsDayKey = dayKey;
    }
    return _supplierReturnsCache!;
  }

  ReviewedSupplierReturn reviewSupplierReturn(
    String supplierId,
    Iterable<String> stockIds,
  ) {
    final supplier = snapshot.suppliers[supplierId];
    if (supplier == null) {
      throw StateError('Choose a saved supplier before preparing a return.');
    }
    final ids = stockIds.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty || ids.length > 500) {
      throw const FormatException(
        'Choose between 1 and 500 due stock entries for one supplier return.',
      );
    }

    final dueById = <String, SupplierReturnCandidate>{
      for (final candidate in supplierReturns)
        if (candidate.supplier.id == supplier.id)
          candidate.medicine.id: candidate,
    };
    final lines = <SupplierReturnLine>[];
    for (final id in ids) {
      final candidate = dueById[id];
      if (candidate == null) {
        throw StateError(
          'One selected stock entry is no longer inside this supplier return window. Refresh the list and review again.',
        );
      }
      final medicine = candidate.medicine;
      final quantity = medicine.quantity;
      if (quantity == null || quantity <= 0) {
        throw StateError(
          'Count the remaining stock before preparing the supplier return.',
        );
      }
      lines.add(
        SupplierReturnLine(
          record: Medicine.fromJson(medicine.toJson()),
          quantity: quantity,
          daysLeft: candidate.daysLeft,
        ),
      );
    }
    lines.sort((a, b) {
      final expiry = a.daysLeft.compareTo(b.daysLeft);
      return expiry != 0 ? expiry : a.record.title.compareTo(b.record.title);
    });
    return ReviewedSupplierReturn(
      baseRevision: snapshot.revision,
      supplier: Supplier.fromJson(supplier.toJson()),
      lines: List.unmodifiable(lines),
      reviewedAt: clock(),
    );
  }

  /// Builds an externally shareable supplier-return review only after stock
  /// writes that were already submitted when this call began have settled.
  ///
  /// The selected IDs are frozen before the await so caller-owned collection
  /// changes cannot silently alter which physical rows are reviewed.
  Future<ReviewedSupplierReturn> reviewSupplierReturnAfterPendingWrites(
    String supplierId,
    Iterable<String> stockIds,
  ) {
    final reviewedIds = List<String>.unmodifiable(stockIds);
    return _readAfterPendingWrites(
      () => reviewSupplierReturn(supplierId, reviewedIds),
    );
  }

  Future<void> applySupplierReturn(ReviewedSupplierReturn review) async {
    await _queueReviewedCommit((returnedAt) {
      final liveSupplier = snapshot.suppliers[review.supplier.id];
      if (liveSupplier == null ||
          liveSupplier.revision != review.supplier.revision ||
          liveSupplier.returnBeforeExpiryDays !=
              review.supplier.returnBeforeExpiryDays) {
        throw StateError(
          'Supplier details changed after this return was reviewed. Review the return list again.',
        );
      }
      final day = civilDay(returnedAt);
      final updates = <Medicine>[];
      for (final line in review.lines) {
        final reviewed = line.record;
        final live = snapshot.records[reviewed.id];
        if (live == null ||
            live.archived ||
            live.sold ||
            live.revision != reviewed.revision ||
            live.supplierId != liveSupplier.id ||
            live.quantity != line.quantity ||
            live.expiry == null) {
          throw StateError(
            'A reviewed stock entry changed before the supplier return was confirmed. Refresh the return list.',
          );
        }
        final daysLeft = civilDay(live.expiry!).difference(day).inDays;
        if (daysLeft < 0 || daysLeft > liveSupplier.returnBeforeExpiryDays) {
          throw StateError(
            'A reviewed stock entry is no longer inside the supplier return window. Refresh the return list.',
          );
        }
        updates.add(
          archiveMedicine(
            live,
            reason: 'Returned to ${liveSupplier.name}',
            at: returnedAt,
          ),
        );
      }
      if (updates.isEmpty) return null;
      return InventoryMutation(
        expectedRevision: snapshot.revision,
        label:
            'Supplier return · ${liveSupplier.name} · ${updates.length} stock entries',
        upserts: updates,
      );
    });
  }

  Future<void> save(Medicine record, {required int expectedRevision}) {
    if (expectedRevision != snapshot.revision) {
      return Future<void>.error(
        StateError('Inventory changed. Reopen this entry before saving.'),
      );
    }

    final reviewed = snapshot.records[record.id];
    final reviewedRevision = reviewed?.revision;
    if (reviewedRevision != null && record.revision != reviewedRevision + 1) {
      return Future<void>.error(
        StateError(
          'This medicine changed while it was being edited. Reopen the live entry before saving.',
        ),
      );
    }

    // A manual editor save is dependent on one physical stock row. Revalidate
    // that row only when its serialized write turn begins, then use the latest
    // global revision for the storage CAS. This preserves real same-row conflict
    // safety without making unrelated settings/supplier/stock traffic reject a
    // valid edit that was already reviewed by the pharmacist.
    return _queueReviewedCommit((operationTime) {
      final live = snapshot.records[record.id];
      final sameReviewedRow = reviewedRevision == null
          ? live == null
          : live != null && live.revision == reviewedRevision;
      if (!sameReviewedRow) {
        throw StateError(
          'This medicine changed while it was being edited. Reopen the live entry before saving.',
        );
      }

      if (record.sold &&
          live?.sold != true &&
          isExpiredOn(record, operationTime)) {
        throw const FormatException(
          'Expired stock cannot be marked SOLD. Remove it with reason Expired so it stays in the correct safety history.',
        );
      }

      var committedRecord = record;
      if (live == null) {
        final intake = appendStockIntakeEvidence(
          medicine: record,
          receivedAt: operationTime,
          quantity: record.quantity ?? 0,
          source: 'recorded',
        );
        if (intake.length != record.intakeHistory.length) {
          committedRecord = Medicine.fromJson(<String, dynamic>{
            ...record.toJson(),
            'intakeHistory': intake
                .map((evidence) => evidence.toJson())
                .toList(growable: false),
          });
        }
      }
      SaleEvent? soldDepletion;
      if (record.sold && live != null && !live.sold) {
        final soldQuantity = record.soldQuantity ?? live.quantity;
        final soldUnitPrice =
            record.soldUnitPricePaise ?? live.unitPricePaise;
        committedRecord = Medicine.fromJson(<String, dynamic>{
          ...record.toJson(),
          // A caller may carry preview/editor metadata captured earlier.
          // The durable SOLD transition owns one authoritative commit instant
          // for the medicine row, sale ledger and audit event.
          'soldAt': operationTime.toIso8601String(),
          'soldQuantity': soldQuantity,
          'soldUnitPricePaise': soldUnitPrice,
        });
        soldDepletion = _knownSoldDepletion(
          committedRecord,
          quantity: soldQuantity,
          occurredAt: operationTime,
          unitPricePaise: soldUnitPrice,
        );
      }

      return InventoryMutation(
        expectedRevision: snapshot.revision,
        label: live == null
            ? 'Added ${committedRecord.name}'
            : 'Edited ${committedRecord.name}',
        upserts: <Medicine>[committedRecord],
        upsertSales: soldDepletion == null
            ? const <SaleEvent>[]
            : <SaleEvent>[soldDepletion],
      );
    });
  }

  Future<void> _updateWarnings(
    WarningSettings Function(WarningSettings current) update,
  ) => _queueCommit(() {
    // Warning windows are preferences, not a review of stock facts. Build the
    // mutation only when its serialized turn begins so a harmless inventory
    // write (or another quick selector tap) cannot make the preference stale.
    // Field-specific callers derive from the latest committed settings, which
    // also prevents one rapid selector change from overwriting the other.
    final current = snapshot.settings;
    final value = update(current);
    if (value.shortDays == current.shortDays && value.months == current.months) {
      return null;
    }
    return InventoryMutation(
      expectedRevision: snapshot.revision,
      label: 'Updated expiry warning windows',
      upserts: const <Medicine>[],
      settings: value,
    ).withOperationTime(clock());
  });

  /// Applies only the warning fields the user explicitly changed.
  ///
  /// Custom-setting dialogs can stay open while another warning preference is
  /// committed elsewhere. Derive omitted fields from the latest serialized
  /// snapshot so an untouched stale form value can never overwrite newer data.
  Future<void> updateWarningFields({int? shortDays, int? months}) {
    if (shortDays == null && months == null) return Future<void>.value();
    return _updateWarnings(
      (current) => WarningSettings.fromJson(<String, dynamic>{
        'shortDays': shortDays ?? current.shortDays,
        'months': months ?? current.months,
      }),
    );
  }

  Future<void> setShortWarningDays(int shortDays) =>
      updateWarningFields(shortDays: shortDays);

  Future<void> setWarningMonths(int months) =>
      updateWarningFields(months: months);

  Future<void> setWarnings(WarningSettings value) =>
      _updateWarnings((_) => value);

  ReviewedMarkSold reviewMarkSold(String id) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('Choose an active stock entry before marking SOLD.');
    }
    if (medicine.sold) {
      throw StateError('This stock entry is already marked SOLD.');
    }
    if (isExpiredOn(medicine, clock())) {
      throw const FormatException(
        'Expired stock cannot be marked SOLD. Remove it with reason Expired instead.',
      );
    }
    return ReviewedMarkSold(
      baseRevision: snapshot.revision,
      record: Medicine.fromJson(medicine.toJson()),
    );
  }

  Future<void> applyMarkSold(ReviewedMarkSold review) async {
    await _queueReviewedCommit((now) {
      final live = snapshot.records[review.stockId];
      if (live == null ||
          live.archived ||
          live.sold ||
          !_sameReviewedMedicine(live, review.record)) {
        throw StateError(
          'The reviewed stock entry changed or is no longer active. Review SOLD again.',
        );
      }
      if (isExpiredOn(live, now)) {
        throw const FormatException(
          'This stock expired after the SOLD review was opened. Remove it with reason Expired instead; nothing was changed.',
        );
      }

      // A known positive stock count is a real depletion fact and belongs in
      // the durable sale ledger, not only in the bounded Activity history.
      // Keep that transition in one helper so editor-driven SOLD and the
      // dedicated SOLD action cannot diverge in analytics.
      final soldQuantity = live.quantity;
      final soldRecord = live.patch({
        'sold': true,
        'quantity': 0,
        'soldAt': now.toIso8601String(),
        'soldQuantity': soldQuantity,
        'soldUnitPricePaise': live.unitPricePaise,
      });
      final soldDepletion = _knownSoldDepletion(
        soldRecord,
        quantity: soldQuantity,
        occurredAt: now,
        unitPricePaise: live.unitPricePaise,
      );
      return InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Marked ${live.name} sold',
        upserts: <Medicine>[soldRecord],
        upsertSales: soldDepletion == null
            ? const <SaleEvent>[]
            : <SaleEvent>[soldDepletion],
      );
    });
  }

  /// Immediate compatibility gateway for callers with no confirmation delay.
  /// User-facing flows use reviewMarkSold/applyMarkSold so stale dialogs are
  /// dependency-scoped rather than tied to unrelated global inventory traffic.
  Future<void> markSold(String id) async {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('This entry is unavailable.');
    }
    if (medicine.sold) return;
    await applyMarkSold(reviewMarkSold(id));
  }

  ReviewedStockAdjustment reviewStockAdjustment(
    String id, {
    required StockAdjustmentKind kind,
    required int quantity,
  }) => _reviewStockAdjustment(
    id,
    kind: kind,
    quantity: quantity,
    operationTime: clock(),
  );

  ReviewedStockAdjustment _reviewStockAdjustment(
    String id, {
    required StockAdjustmentKind kind,
    required int quantity,
    required DateTime operationTime,
  }) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('Choose an active stock entry before changing stock.');
    }
    if (quantity < 0 || quantity > _maxStockQuantity) {
      throw const FormatException(
        'Stock quantity is outside the supported range.',
      );
    }

    final current = medicine.quantity;
    late final int after;
    switch (kind) {
      case StockAdjustmentKind.setExact:
        if (medicine.sold && quantity > 0) {
          throw StateError(
            'This entry is SOLD. Use Receive stock so Aaris can explicitly reopen it and preserve the sold-history facts.',
          );
        }
        after = quantity;
      case StockAdjustmentKind.receive:
        if (quantity < 1) {
          throw const FormatException(
            'Received stock must be a positive whole-number quantity.',
          );
        }
        if (isExpiredOn(medicine, operationTime)) {
          throw const FormatException(
            'This physical stock entry is expired. Add a new stock entry with its own batch and expiry instead of receiving stock into the expired entry.',
          );
        }
        if (current == null) {
          throw const FormatException(
            'Current stock quantity is unknown. Verify or set the physical count first; Aaris will not add received units to an unknown baseline.',
          );
        }
        if (quantity > _maxStockQuantity - current) {
          throw const FormatException(
            'Received stock would exceed the supported quantity range.',
          );
        }
        after = current + quantity;
    }

    return ReviewedStockAdjustment(
      baseRevision: snapshot.revision,
      stockId: medicine.id,
      recordRevision: medicine.revision,
      kind: kind,
      requestedQuantity: quantity,
      beforeQuantity: current,
      afterQuantity: after,
      wasSold: medicine.sold,
    );
  }

  Future<void> applyStockAdjustment(ReviewedStockAdjustment review) async {
    await _queueReviewedCommit((operationTime) {
      final live = snapshot.records[review.stockId];
      if (live == null ||
          live.archived ||
          live.revision != review.recordRevision) {
        throw StateError(
          'The reviewed stock entry changed or is no longer active. Review it again.',
        );
      }
      final fresh = _reviewStockAdjustment(
        live.id,
        kind: review.kind,
        quantity: review.requestedQuantity,
        operationTime: operationTime,
      );
      if (fresh.beforeQuantity != review.beforeQuantity ||
          fresh.afterQuantity != review.afterQuantity ||
          fresh.wasSold != review.wasSold) {
        throw StateError(
          'Stock facts changed after review. Nothing was saved; review the action again.',
        );
      }
      if (!fresh.changesQuantity &&
          !(fresh.kind == StockAdjustmentKind.receive && fresh.wasSold)) {
        return null;
      }
      final changes = <String, dynamic>{'quantity': fresh.afterQuantity};
      if (fresh.kind == StockAdjustmentKind.receive) {
        final intake = appendStockIntakeEvidence(
          medicine: live,
          receivedAt: operationTime,
          quantity: fresh.requestedQuantity,
          source: 'receive',
        );
        if (intake.length != live.intakeHistory.length) {
          changes['intakeHistory'] = intake
              .map((evidence) => evidence.toJson())
              .toList(growable: false);
        }
      }
      if (fresh.kind == StockAdjustmentKind.receive && live.sold) {
        changes.addAll({
          'sold': false,
          'soldAt': null,
          'soldQuantity': null,
          'soldUnitPricePaise': null,
        });
      }
      final label = fresh.kind == StockAdjustmentKind.receive
          ? 'Received stock · ${live.name} · +${fresh.requestedQuantity} units · ${fresh.beforeQuantity}→${fresh.afterQuantity}'
          : 'Corrected stock · ${live.name} · ${fresh.beforeQuantity == null ? 'unknown' : fresh.beforeQuantity}→${fresh.afterQuantity} units';
      return InventoryMutation(
        expectedRevision: fresh.baseRevision,
        label: label,
        upserts: [live.patch(changes)],
      );
    });
  }

  ReviewedSale reviewSale(
    String id, {
    required int quantity,
    int? totalAmountPaise,
    DateTime? occurredAt,
    bool markSoldOut = false,
    Medicine? reviewedRecord,
  }) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('This stock entry is unavailable.');
    }
    if (reviewedRecord != null &&
        !_sameReviewedMedicine(medicine, reviewedRecord)) {
      throw StateError(
        'This stock entry changed while the sale dialog was open. Review the live medicine again before recording the sale.',
      );
    }
    if (medicine.sold) {
      throw StateError('Restock this medicine before recording another sale.');
    }
    if (quantity < 1 || quantity > _maxStockQuantity) {
      throw const FormatException(
        'Sale quantity must be a positive whole number.',
      );
    }
    if (totalAmountPaise != null &&
        (totalAmountPaise < 0 || totalAmountPaise > maxExactPaise)) {
      throw const FormatException(
        'Sale amount is outside the supported range.',
      );
    }
    final time = occurredAt ?? clock();
    if (civilDay(time).isAfter(today)) {
      throw const FormatException('A sale cannot be recorded in the future.');
    }
    validateDispensingDate(medicine, time);
    final current = medicine.quantity;
    if (current != null && quantity > current) {
      throw FormatException(
        'Only $current units are recorded in stock. Correct the stock first or enter a smaller sale.',
      );
    }
    if (markSoldOut && current == null) {
      throw const FormatException(
        'Stock quantity is unknown, so this sale cannot safely mark the entry completely finished. Verify the physical quantity first or use the explicit whole-stock SOLD action.',
      );
    }
    if (markSoldOut && current != null && quantity != current) {
      throw const FormatException(
        'To mark this entry out of stock, the sale quantity must equal all remaining units.',
      );
    }

    return ReviewedSale(
      baseRevision: snapshot.revision,
      record: Medicine.fromJson(medicine.toJson()),
      quantity: quantity,
      totalAmountPaise: totalAmountPaise,
      occurredAt: time,
      markSoldOut: markSoldOut,
    );
  }

  Future<void> applySale(ReviewedSale review) async {
    await _queueReviewedCommit((_) {
      final live = snapshot.records[review.stockId];
      if (live == null ||
          live.archived ||
          live.sold ||
          !_sameReviewedMedicine(live, review.record)) {
        throw StateError(
          'The reviewed stock entry changed or is no longer active. Review the sale again; nothing was saved.',
        );
      }
      final fresh = reviewSale(
        live.id,
        quantity: review.quantity,
        totalAmountPaise: review.totalAmountPaise,
        occurredAt: review.occurredAt,
        markSoldOut: review.markSoldOut,
        reviewedRecord: review.record,
      );
      final medicine = fresh.record;
      final current = medicine.quantity;
      final remaining = current == null ? null : current - fresh.quantity;
      final sale = SaleEvent(
        id: newId(),
        stockId: medicine.id,
        medicineName: medicine.name,
        strength: medicine.strength,
        form: medicine.form,
        salt: medicine.salt,
        quantity: fresh.quantity,
        occurredAt: fresh.occurredAt,
        totalAmountPaise: fresh.totalAmountPaise,
        savedUnitPricePaise: medicine.unitPricePaise,
      );
      final updated = medicine.patch({
        'quantity': fresh.markSoldOut ? 0 : remaining,
        if (fresh.markSoldOut) ...{
          'sold': true,
          'soldAt': fresh.occurredAt.toIso8601String(),
          'soldQuantity': current,
          'soldUnitPricePaise': medicine.unitPricePaise,
        },
      });
      return InventoryMutation(
        expectedRevision: fresh.baseRevision,
        label:
            'Recorded sale · ${medicine.name} · ${fresh.quantity} ${fresh.quantity == 1 ? 'unit' : 'units'}${fresh.markSoldOut ? ' · marked sold' : ''}',
        upserts: [updated],
        upsertSales: [sale],
      );
    });
  }

  /// Immediate compatibility gateway. New user-facing confirmation flows should
  /// use reviewSale/applySale so harmless unrelated inventory traffic does not
  /// invalidate an otherwise exact pharmacist review.
  Future<void> recordSale(
    String id, {
    required int quantity,
    int? totalAmountPaise,
    DateTime? occurredAt,
    bool markSoldOut = false,
    int? expectedRevision,
  }) async {
    if (expectedRevision != null && expectedRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed. Reopen this entry before recording a sale.',
      );
    }
    await applySale(
      reviewSale(
        id,
        quantity: quantity,
        totalAmountPaise: totalAmountPaise,
        occurredAt: occurredAt,
        markSoldOut: markSoldOut,
      ),
    );
  }

  ReviewedArchive reviewArchive(String id, String reason) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('Choose an active stock entry before removing it.');
    }
    final cleanReason = reason.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleanReason.isEmpty || cleanReason.length > 300) {
      throw const FormatException('Choose a valid removal reason.');
    }
    return ReviewedArchive(
      baseRevision: snapshot.revision,
      record: Medicine.fromJson(medicine.toJson()),
      reason: cleanReason,
    );
  }

  Future<void> applyArchive(ReviewedArchive review) async {
    await _queueReviewedCommit((removedAt) {
      final live = snapshot.records[review.stockId];
      if (live == null ||
          live.archived ||
          !_sameReviewedMedicine(live, review.record)) {
        throw StateError(
          'The reviewed stock entry changed or is no longer active. Review removal again.',
        );
      }
      final fresh = reviewArchive(live.id, review.reason);
      return InventoryMutation(
        expectedRevision: fresh.baseRevision,
        label: 'Removed ${live.name} · ${fresh.reason}',
        upserts: [archiveMedicine(live, reason: fresh.reason, at: removedAt)],
      );
    });
  }

  /// Immediate compatibility gateway. User-facing confirmation flows should
  /// prepare an exact-row review and apply it only after the user confirms.
  Future<void> archive(
    String id,
    String reason, {
    int? expectedRevision,
  }) async {
    if (expectedRevision != null && expectedRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed. Reopen this entry before removing it.',
      );
    }
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) return;
    await applyArchive(reviewArchive(id, reason));
  }

  BulkArchiveReview reviewArchiveAll() => BulkArchiveReview(
    baseRevision: snapshot.revision,
    activeIds: records.where((m) => !m.archived).map((m) => m.id),
  );

  Future<void> applyArchiveAll(BulkArchiveReview review) async {
    if (review.baseRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed after bulk removal was reviewed. Start the protected removal flow again.',
      );
    }
    final activeIds = records
        .where((m) => !m.archived)
        .map((m) => m.id)
        .toSet();
    if (!setEquals(activeIds, review.activeIds)) {
      throw StateError(
        'The active inventory no longer matches the reviewed bulk action. Nothing was removed.',
      );
    }
    if (activeIds.isEmpty) return;
    final orderedIds = activeIds.toList()..sort();
    final removedAt = clock();
    await _commit(
      InventoryMutation(
        expectedRevision: review.baseRevision,
        label: 'Removed all inventory · ${orderedIds.length} stock entries',
        upserts: [
          for (final id in orderedIds)
            archiveMedicine(
              snapshot.records[id]!,
              reason: 'Protected bulk removal',
              at: removedAt,
            ),
        ],
      ),
      operationTime: removedAt,
    );
  }

  @Deprecated('Use reviewArchiveAll() followed by applyArchiveAll(review).')
  Future<void> archiveAll({int? expectedRevision}) => Future<void>.error(
    StateError(
      'Bulk removal requires a reviewed inventory snapshot and the protected confirmation flow.',
    ),
  );

  ReviewedArchivedRestore reviewArchivedRestore(String id) {
    final medicine = snapshot.records[id];
    if (medicine == null || !medicine.archived) {
      throw StateError('Choose a removed stock entry before restoring it.');
    }
    return ReviewedArchivedRestore(
      baseRevision: snapshot.revision,
      stockId: medicine.id,
      recordRevision: medicine.revision,
      archiveReason: medicine.archiveReason,
      archivedAt: medicine.archivedAt,
    );
  }

  Future<void> applyArchivedRestore(ReviewedArchivedRestore review) async {
    await _queueReviewedCommit((_) {
      final live = snapshot.records[review.stockId];
      if (live == null ||
          !live.archived ||
          live.revision != review.recordRevision ||
          live.archiveReason != review.archiveReason ||
          live.archivedAt != review.archivedAt) {
        throw StateError(
          'The reviewed removed-stock entry changed or is no longer removed. Review it again.',
        );
      }
      final fresh = reviewArchivedRestore(live.id);
      return InventoryMutation(
        expectedRevision: fresh.baseRevision,
        label: 'Restored ${live.name}',
        upserts: [restoreArchivedMedicine(live)],
      );
    });
  }

  /// Compatibility gateway for existing internal callers. It captures and
  /// applies one review immediately, leaving no user-confirmation delay in
  /// which the inventory can become stale. User-facing flows should call the
  /// explicit review/apply pair so they can show the exact facts being restored.
  Future<void> restoreArchived(String id) async {
    final medicine = snapshot.records[id];
    if (medicine == null || !medicine.archived) return;
    await applyArchivedRestore(reviewArchivedRestore(id));
  }

  List<MedicineVersion> versionsFor(String id) {
    final versions = <MedicineVersion>[];
    for (final event in snapshot.events) {
      final beforeRaw = event['before'];
      if (beforeRaw is! Map || !beforeRaw.containsKey(id)) continue;
      final value = beforeRaw[id];
      if (value is! Map) continue;
      try {
        versions.add(
          MedicineVersion(
            sourceRevision: snapshot.revision,
            eventRevision: event['revision'] as int,
            label: event['label'] as String,
            time: DateTime.parse(event['time'] as String),
            record: Medicine.fromJson(Map<String, dynamic>.from(value)),
          ),
        );
      } catch (_) {
        // A corrupt legacy history row must not block the live inventory.
      }
    }
    return versions;
  }

  Future<void> restoreVersion(MedicineVersion version) async {
    if (version.sourceRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed after this history was opened. Reopen version history.',
      );
    }
    final current = snapshot.records[version.record.id];
    final restored = Medicine.fromJson({
      ...version.record.toJson(),
      'revision': (current?.revision ?? version.record.revision) + 1,
    });
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Restored previous version · ${restored.name}',
        upserts: [restored],
      ),
    );
  }

  bool get canUndo =>
      snapshot.events.isNotEmpty &&
      snapshot.events.first['revision'] == snapshot.revision &&
      snapshot.events.first['undoable'] == true &&
      snapshot.events.first['undone'] != true;

  ReviewedUndo reviewUndo() {
    if (!canUndo) throw StateError('No current change is available to undo.');
    final event = snapshot.events.first;
    return ReviewedUndo(
      baseRevision: snapshot.revision,
      eventId: event['id'] as String,
      eventRevision: event['revision'] as int,
      label: '${event['label']}',
    );
  }

  Future<void> applyUndo(ReviewedUndo review) => _queueCommit(() {
    if (snapshot.revision != review.baseRevision || !canUndo) {
      throw StateError(
        'Activity changed after this Undo was reviewed. Review the latest change again.',
      );
    }
    final event = snapshot.events.first;
    if (event['id'] != review.eventId ||
        event['revision'] != review.eventRevision ||
        '${event['label']}' != review.label) {
      throw StateError(
        'The reviewed activity is no longer the latest change. Review Undo again.',
      );
    }

    final before = Map<String, dynamic>.from(event['before'] as Map);
    final supplierBefore = Map<String, dynamic>.from(
      event['supplierBefore'] as Map? ?? const {},
    );
    final salesBefore = Map<String, dynamic>.from(
      event['salesBefore'] as Map? ?? const {},
    );
    final upserts = <Medicine>[], removes = <String>[];
    final upsertSuppliers = <Supplier>[], removeSuppliers = <String>[];
    final upsertSales = <SaleEvent>[], removeSales = <String>[];
    for (final entry in before.entries) {
      if (entry.value == null) {
        removes.add(entry.key);
      } else {
        final record = Medicine.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        upserts.add(
          Medicine.fromJson({
            ...record.toJson(),
            'revision':
                (snapshot.records[entry.key]?.revision ?? record.revision) + 1,
          }),
        );
      }
    }
    for (final entry in supplierBefore.entries) {
      if (entry.value == null) {
        removeSuppliers.add(entry.key);
      } else {
        final supplier = Supplier.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        upsertSuppliers.add(
          Supplier.fromJson({
            ...supplier.toJson(),
            'revision':
                (snapshot.suppliers[entry.key]?.revision ?? supplier.revision) + 1,
          }),
        );
      }
    }
    for (final entry in salesBefore.entries) {
      if (entry.value == null) {
        removeSales.add(entry.key);
      } else {
        upsertSales.add(
          SaleEvent.fromJson(Map<String, dynamic>.from(entry.value as Map)),
        );
      }
    }
    return InventoryMutation(
      expectedRevision: review.baseRevision,
      label: 'Undo: ${event['label']}',
      upserts: upserts,
      upsertSuppliers: upsertSuppliers,
      upsertSales: upsertSales,
      removeIds: removes,
      removeSupplierIds: removeSuppliers,
      removeSaleIds: removeSales,
      settings: WarningSettings.fromJson(
        Map<String, dynamic>.from(event['settingsBefore'] as Map),
      ),
      undoEventId: review.eventId,
      undoable: false,
    );
  });

  Future<void> undo() => applyUndo(reviewUndo());

  /// Waits for inventory writes that were already queued when this call began.
  ///
  /// External read outputs such as exports, backups and purchase orders use
  /// this barrier so they cannot publish a snapshot older than an action the
  /// pharmacist already submitted. Writes queued later keep their normal turn.
  Future<void> settlePendingWrites() async {
    final barrier = _writes;
    await barrier;
    if (_disposed) throw StateError('App is closed.');
  }

  Future<T> _readAfterPendingWrites<T>(T Function() read) async {
    await settlePendingWrites();
    return read();
  }

  Future<PharmacyExport> exportAfterPendingWrites() =>
      _readAfterPendingWrites(export);

  Future<PharmacyBackup> createBackupAfterPendingWrites() =>
      _readAfterPendingWrites(createBackup);

  PharmacyExport export() => PharmacyExport(
    revision: snapshot.revision,
    records: records,
    suppliers: suppliers,
    sales: sales,
    today: today,
  );

  PharmacyBackup createBackup() => PharmacyBackup(
    createdAt: clock(),
    sourceRevision: snapshot.revision,
    settings: settings,
    records: snapshot.records,
    suppliers: snapshot.suppliers,
    sales: snapshot.sales,
    soldValue: snapshot.soldValue,
    unknownSold: snapshot.unknownSold,
  );

  Future<BackupReview> reviewBackup(String input) async => BackupReview(
    backup: await compute(_parseBackup, input),
    currentRevision: snapshot.revision,
  );

  Future<void> restoreBackup(BackupReview review) async {
    if (review.currentRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed after this backup was reviewed. Review it again before restoring.',
      );
    }
    final restored = <Medicine>[];
    final restoreStartedAt = clock();
    for (final record in review.backup.records.values) {
      final current = snapshot.records[record.id];
      if (current == null) {
        // On a fresh phone there is no stale local row to invalidate, so reuse
        // the already validated immutable record instead of cloning the entire
        // imported stock set in memory.
        restored.add(record);
        continue;
      }
      restored.add(
        Medicine.fromJson({
          ...record.toJson(),
          'revision': current.revision > record.revision
              ? current.revision + 1
              : record.revision + 1,
        }),
      );
    }
    for (final record in snapshot.records.values) {
      if (review.backup.records.containsKey(record.id)) continue;
      if (!record.archived) {
        var archived = archiveMedicine(
          record,
          reason: 'Not present in restored backup',
          at: restoreStartedAt,
        );
        if (archived.supplierId.isNotEmpty &&
            !review.backup.suppliers.containsKey(archived.supplierId)) {
          archived = archived.patch({'supplierId': ''});
        }
        restored.add(archived);
      } else if (record.supplierId.isNotEmpty &&
          !review.backup.suppliers.containsKey(record.supplierId)) {
        // Removed history stays available after restore, but it cannot retain
        // a foreign key to a supplier intentionally absent from the backup.
        restored.add(record.patch({'supplierId': ''}));
      }
    }
    final restoredSuppliers = <Supplier>[];
    for (final supplier in review.backup.suppliers.values) {
      final current = snapshot.suppliers[supplier.id];
      restoredSuppliers.add(
        current == null
            ? supplier
            : Supplier.fromJson({
                ...supplier.toJson(),
                'revision': current.revision > supplier.revision
                    ? current.revision + 1
                    : supplier.revision + 1,
              }),
      );
    }

    // Rows preserved only as Removed history must not keep a dangling supplier
    // link when a full backup intentionally omits that supplier.
    for (var i = 0; i < restored.length; i++) {
      final record = restored[i];
      if (record.archived &&
          record.supplierId.isNotEmpty &&
          !review.backup.suppliers.containsKey(record.supplierId)) {
        restored[i] = record.patch({'supplierId': ''});
      }
    }

    await _commit(
      InventoryMutation(
        expectedRevision: review.currentRevision,
        label:
            'Restored backup · ${review.activeMedicines} active medicines · ${review.sales} sales',
        upserts: restored,
        upsertSuppliers: restoredSuppliers,
        upsertSales: review.backup.sales.values.toList(),
        removeSupplierIds: snapshot.suppliers.keys
            .where((id) => !review.backup.suppliers.containsKey(id))
            .toList(),
        removeSaleIds: snapshot.sales.keys
            .where((id) => !review.backup.sales.containsKey(id))
            .toList(),
        settings: review.backup.settings,
        soldValueOverride: review.backup.soldValue,
        unknownSoldOverride: review.backup.unknownSold,
      ),
      operationTime: restoreStartedAt,
    );
  }

  AiPlan review(String input) => parseAiPlan(
    input,
    snapshot.records,
    snapshot.revision,
    snapshot.receipts,
    clock(),
    suppliers: snapshot.suppliers,
  );

  Future<AiPlan> reviewAsync(String input) => compute(_parseReview, {
    'input': input,
    'records': snapshot.records,
    'suppliers': snapshot.suppliers,
    'revision': snapshot.revision,
    'receipts': snapshot.receipts,
    'now': clock(),
  });

  void cancelAi() {
    _cancelAi = true;
  }

  Medicine _materializeAiChangeAtCommit(
    AiChange change,
    DateTime operationTime,
  ) {
    if (change.operation != 'mark_sold' && change.operation != 'remove') {
      var materialized = Medicine.fromJson(change.after.toJson());
      if (change.operation == 'add' || change.operation == 'restock') {
        final intake = appendStockIntakeEvidence(
          medicine: materialized,
          receivedAt: operationTime,
          quantity: materialized.quantity ?? 0,
          source: 'ai',
        );
        if (intake.length != materialized.intakeHistory.length) {
          materialized = Medicine.fromJson(<String, dynamic>{
            ...materialized.toJson(),
            'intakeHistory': intake
                .map((evidence) => evidence.toJson())
                .toList(growable: false),
          });
        }
      }
      return materialized;
    }

    final reviewed = change.before;
    if (reviewed == null) {
      throw StateError(
        'A reviewed AI lifecycle change is missing its original stock entry. Review the AI result again.',
      );
    }
    final live = snapshot.records[reviewed.id];
    if (live == null || !_sameReviewedMedicine(live, reviewed)) {
      throw StateError(
        'A reviewed AI stock entry changed before apply. Review the AI result again.',
      );
    }

    if (change.operation == 'mark_sold') {
      if (live.archived || live.sold) {
        throw StateError(
          'The reviewed stock entry is no longer active. Review SOLD again.',
        );
      }
      if (isExpiredOn(live, operationTime)) {
        throw const FormatException(
          'This stock expired after the AI review was prepared. Remove it with reason Expired instead; nothing was changed.',
        );
      }
      return live.patch({
        'sold': true,
        'quantity': 0,
        'soldAt': operationTime.toIso8601String(),
        'soldQuantity': live.quantity,
        'soldUnitPricePaise': live.unitPricePaise,
      });
    }

    if (live.archived) {
      throw StateError(
        'The reviewed stock entry is already removed. Review the AI result again.',
      );
    }
    return archiveMedicine(
      live,
      reason: 'AI reviewed removal',
      at: operationTime,
    );
  }

  Future<void> applyAi(AiPlan plan, Set<int> selected) async {
    if (aiPreparing) throw StateError('Another AI plan is preparing.');
    if (plan.baseRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed after review. Review a fresh snapshot.',
      );
    }
    final selection = Set<int>.unmodifiable(selected);
    if (selection.any((i) => i < 0 || i >= plan.changes.length)) {
      throw StateError('The AI selection is invalid. Review the result again.');
    }
    if (selection.isEmpty) return;
    aiPreparing = true;
    _cancelAi = false;
    preparedActions = 0;
    _emit();
    try {
      final selectedIndices = selection.toList()..sort();
      final selectedChanges = <AiChange>[];
      for (var start = 0; start < selectedIndices.length; start += 25) {
        if (_cancelAi || _disposed) {
          throw StateError('Cancelled. No inventory changes were saved.');
        }
        final end = (start + 25).clamp(0, selectedIndices.length);
        for (var position = start; position < end; position++) {
          selectedChanges.add(plan.changes[selectedIndices[position]]);
        }
        // Preparation is proportional to the work the owner actually approved.
        // Do not scan/repaint through thousands of unselected suggestions.
        preparedActions = end;
        _emit();
        // Yield once per real selected batch so Cancel remains responsive
        // without adding an artificial fixed delay to the save path.
        await Future<void>.delayed(Duration.zero);
      }
      if (_cancelAi || _disposed) {
        throw StateError('Cancelled. No inventory changes were saved.');
      }

      // Lifecycle metadata belongs to the durable apply, not the earlier AI
      // preview. Capture one authoritative instant after preparation/cancellation
      // and rebuild SOLD/removal transitions from the unchanged reviewed row.
      // This mirrors the manual review/apply flows: stock that expires while a
      // review is open fails closed, and audit + lifecycle timestamps stay equal.
      final operationTime = clock();
      final changes = selectedChanges
          .map((change) => _materializeAiChangeAtCommit(change, operationTime))
          .toList(growable: false);
      await _commit(
        InventoryMutation(
          expectedRevision: plan.baseRevision,
          label: 'AI: applied ${changes.length} reviewed changes',
          upserts: changes,
          requestId: plan.requestId,
        ),
        operationTime: operationTime,
      );
    } finally {
      aiPreparing = false;
      _emit();
    }
  }

  /// Returns a bounded ordered window for an empty-query inventory browse.
  ///
  /// The native app keeps sorting off the UI isolate and transfers only the
  /// records the visible list can consume. Larger inventories are revealed
  /// incrementally by SearchScreen instead of allocating/transferring every
  /// matching SearchHit just to open the Stock tab.
  Future<List<SearchHit>> browse(
    SearchScope scope, {
    required int limit,
  }) async {
    final boundedLimit = limit < 1
        ? 1
        : limit > 100000
        ? 100000
        : limit;
    final data = _stableRecords;
    final datasetRevision = _searchDatasetEpoch;
    final selectedSettings = settings;
    final date = today;
    if (kIsWeb || !backgroundSearch) {
      final visible = data
          .where(
            (medicine) =>
                inScope(medicine, scope, selectedSettings, date),
          )
          .toList(growable: false)
        ..sort((a, b) => expiryOrder(a, b, date));
      return visible
          .take(boundedLimit)
          .map((medicine) => SearchHit(medicine.id, 1, 'Inventory', ''))
          .toList(growable: false);
    }
    return _searchWorker.browseActive(
      data,
      datasetRevision,
      scope,
      selectedSettings,
      date,
      limit: boundedLimit,
    );
  }

  Future<List<SearchHit>> search(String raw, SearchScope scope) async {
    if (raw.trim().isEmpty) {
      // Preserve the public search contract for non-UI callers while avoiding
      // construction of the fuzzy index for what is only an ordered browse.
      return browse(scope, limit: 100000);
    }
    final data = _stableRecords;
    final datasetRevision = _searchDatasetEpoch;
    final selectedSettings = settings;
    final date = today;
    // Isolate.run transfers the result; widgets bind it to their request generation.
    if (kIsWeb || !backgroundSearch) {
      if (_webSearch == null || _webSearchDatasetEpoch != datasetRevision) {
        _webSearch = MedicineSearch(data);
        _webSearchDatasetEpoch = datasetRevision;
        _webSearchIndexBuilds++;
      }
      return _webSearch!.search(
        raw,
        scope,
        selectedSettings,
        date,
        limit: 150,
      );
    }
    return _searchWorker.search(
      data,
      datasetRevision,
      raw,
      scope,
      selectedSettings,
      date,
    );
  }

  /// Returns a bounded chronological window over archived rows without
  /// constructing the fuzzy removed-stock index.
  Future<List<SearchHit>> browseArchived({required int limit}) async {
    final boundedLimit = limit < 1
        ? 1
        : limit > 100000
        ? 100000
        : limit;
    final data = _stableRecords;
    final datasetRevision = _archivedSearchDatasetEpoch;
    if (kIsWeb || !backgroundSearch) {
      final visible = data
          .where((medicine) => medicine.archived)
          .toList(growable: false)
        ..sort(archivedOrder);
      return visible
          .take(boundedLimit)
          .map((medicine) => SearchHit(medicine.id, 1, 'Removed stock', ''))
          .toList(growable: false);
    }
    return _archivedSearchWorker.browseArchived(
      data,
      datasetRevision,
      limit: boundedLimit,
    );
  }

  /// Read-only fuzzy lookup over Removed stock. This is a projection over the
  /// same authoritative Medicine objects, not a second database. The native
  /// path uses the existing background search isolate and builds the archive
  /// index only when this feature is actually opened.
  Future<List<SearchHit>> searchArchived(String raw) async {
    if (raw.trim().isEmpty) {
      return browseArchived(limit: MedicineSearch.maxArchivedResults);
    }
    final data = _stableRecords;
    final datasetRevision = _archivedSearchDatasetEpoch;
    final date = today;
    if (kIsWeb || !backgroundSearch) {
      if (_webArchivedSearch == null ||
          _webArchivedSearchDatasetEpoch != datasetRevision) {
        _webArchivedSearch = MedicineSearch(
          data.where((medicine) => medicine.archived),
          includeArchived: true,
        );
        _webArchivedSearchDatasetEpoch = datasetRevision;
        _webArchivedSearchIndexBuilds++;
      }
      return _webArchivedSearch!.searchArchived(
        raw,
        date,
        limit: 150,
      );
    }
    return _archivedSearchWorker.searchArchived(
      data,
      datasetRevision,
      raw,
      date,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final initializing = _initializing;
    _searchWorker.close();
    _archivedSearchWorker.close();
    _midnight?.cancel();
    _cancelAi = true;
    unawaited(_closeWhenIdle(initializing));
    super.dispose();
  }

  Future<void> _closeWhenIdle(Future<void>? initializing) async {
    try {
      await initializing;
    } catch (_) {
      // A failed open still needs the same single storage close path.
    }
    try {
      await _writes;
    } catch (_) {
      // The write caller receives its error; disposal only owns cleanup.
    }
    try {
      await storage.close();
    } catch (_) {
      // Widget disposal cannot surface an asynchronous storage-close failure.
    }
  }
}

AiPlan _parseReview(Map<String, dynamic> data) => parseAiPlan(
  data['input'] as String,
  data['records'] as Map<String, Medicine>,
  data['revision'] as int,
  data['receipts'] as Set<String>,
  data['now'] as DateTime,
  suppliers: data['suppliers'] as Map<String, Supplier>,
);

PharmacyBackup _parseBackup(String input) => PharmacyBackup.parse(input);

class MedicineVersion {
  const MedicineVersion({
    required this.sourceRevision,
    required this.eventRevision,
    required this.label,
    required this.time,
    required this.record,
  });

  final int sourceRevision;
  final int eventRevision;
  final String label;
  final DateTime time;
  final Medicine record;
}
