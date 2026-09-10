import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/inventory_database.dart';
import '../domain/ai_protocol.dart';
import '../domain/backup.dart';
import '../domain/dispensing_plan.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/search.dart';
import '../domain/tracking.dart';
import '../services/search_worker.dart';

const _maxStockQuantity = 100000000;

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
  final _searchWorker = SearchWorker();
  MedicineSearch? _webSearch, _webArchivedSearch;
  int _webRevision = -1, _webArchivedRevision = -1;
  DateTime get today => civilDay(clock());
  WarningSettings get settings => snapshot.settings;
  Iterable<Medicine> get records => snapshot.records.values;
  Iterable<SaleEvent> get sales => snapshot.sales.values;
  InventoryStats get stats => InventoryStats(records, today);
  TrackingStats tracking(TrackingRange range) => TrackingStats(
    medicines: records,
    sales: sales,
    range: range,
    today: today,
  );

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
    ready = true;
    _scheduleMidnight();
    _emit();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
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

    // A FEFO confirmation is bound to the physical rows and allocation the
    // pharmacist actually reviewed, not unrelated inventory traffic. When the
    // global revision moved, every reviewed allocation row must still have its
    // exact revision, then FEFO is recomputed from the live Medicine Database.
    // Any new/changed earlier-priority batch changes the plan and fails closed.
    // The final commit still uses the current global revision, so a later race is
    // rejected by the authoritative persistence compare-and-swap boundary.
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

    await _commit(
      InventoryMutation(
        expectedRevision: safeReview.baseRevision,
        label:
            'FEFO sale · ${plan.title} · ${plan.requestedQuantity} units · ${plan.allocations.length} ${plan.allocations.length == 1 ? 'batch' : 'batches'}',
        upserts: updates,
        upsertSales: saleEvents,
      ),
    );
  }

  Future<void> _commit(InventoryMutation mutation) {
    // Stamp once at the authoritative controller boundary. Every downstream
    // date-sensitive guard and the durable audit event uses this exact instant,
    // so a transaction cannot observe two different business days around
    // midnight or diverge from an injected/test business clock.
    final committedMutation = mutation.withOperationTime(clock());
    final result = _writes.then((_) async {
      if (_disposed) throw StateError('App is closed.');
      snapshot = await storage.commit(committedMutation);
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
        upserts: [
          m.patch({
            'sold': true,
            'quantity': 0,
            'soldAt': now.toIso8601String(),
            'soldQuantity': m.quantity,
            'soldUnitPricePaise': m.unitPricePaise,
          }),
        ],
      ),
    );
  }

  ReviewedStockAdjustment reviewStockAdjustment(
    String id, {
    required StockAdjustmentKind kind,
    required int quantity,
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
        if (isExpiredOn(medicine, today)) {
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
    // This confirmation belongs to one exact physical stock row. An unrelated
    // medicine being added, sold or edited must not force the pharmacist to
    // repeat a still-valid review. The row revision and reviewed stock facts are
    // revalidated below; the final commit rebases onto the live global revision.
    final live = snapshot.records[review.stockId];
    if (live == null ||
        live.archived ||
        live.revision != review.recordRevision) {
      throw StateError(
        'The reviewed stock entry changed or is no longer active. Review it again.',
      );
    }

    final fresh = reviewStockAdjustment(
      live.id,
      kind: review.kind,
      quantity: review.requestedQuantity,
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
      return;
    }

    final changes = <String, dynamic>{'quantity': fresh.afterQuantity};
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
    await _commit(
      InventoryMutation(
        expectedRevision: fresh.baseRevision,
        label: label,
        upserts: [live.patch(changes)],
      ),
    );
  }

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
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('This stock entry is unavailable.');
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
    final remaining = current == null ? null : current - quantity;
    final sale = SaleEvent(
      id: newId(),
      stockId: medicine.id,
      medicineName: medicine.name,
      strength: medicine.strength,
      form: medicine.form,
      salt: medicine.salt,
      quantity: quantity,
      occurredAt: time,
      totalAmountPaise: totalAmountPaise,
      savedUnitPricePaise: medicine.unitPricePaise,
    );
    final updated = medicine.patch({
      'quantity': markSoldOut ? 0 : remaining,
      if (markSoldOut) ...{
        'sold': true,
        'soldAt': time.toIso8601String(),
        'soldQuantity': current,
        'soldUnitPricePaise': medicine.unitPricePaise,
      },
    });
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label:
            'Recorded sale · ${medicine.name} · $quantity ${quantity == 1 ? 'unit' : 'units'}${markSoldOut ? ' · marked sold' : ''}',
        upserts: [updated],
        upsertSales: [sale],
      ),
    );
  }

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
    final m = snapshot.records[id];
    if (m == null || m.archived) return;
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Removed ${m.name} · $reason',
        upserts: [archiveMedicine(m, reason: reason, at: clock())],
      ),
    );
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
    // Restore is exact-row recovery. Preserve a valid pharmacist confirmation
    // across unrelated database traffic while binding it to the same archived
    // row revision, removal reason and removal timestamp. Cross-row integrity is
    // still enforced at the persistence boundary.
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
    await _commit(
      InventoryMutation(
        expectedRevision: fresh.baseRevision,
        label: 'Restored ${live.name}',
        upserts: [restoreArchivedMedicine(live)],
      ),
    );
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

  Future<void> undo() async {
    if (!canUndo) throw StateError('No current change is available to undo.');
    final event = snapshot.events.first;
    final before = Map<String, dynamic>.from(event['before'] as Map);
    final salesBefore = Map<String, dynamic>.from(
      event['salesBefore'] as Map? ?? const {},
    );
    final upserts = <Medicine>[], removes = <String>[];
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
    for (final entry in salesBefore.entries) {
      if (entry.value == null) {
        removeSales.add(entry.key);
      } else {
        upsertSales.add(
          SaleEvent.fromJson(Map<String, dynamic>.from(entry.value as Map)),
        );
      }
    }
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Undo: ${event['label']}',
        upserts: upserts,
        upsertSales: upsertSales,
        removeIds: removes,
        removeSaleIds: removeSales,
        settings: WarningSettings.fromJson(
          Map<String, dynamic>.from(event['settingsBefore'] as Map),
        ),
        undoEventId: event['id'] as String,
        undoable: false,
      ),
    );
  }

  PharmacyExport export() => PharmacyExport(
    revision: snapshot.revision,
    records: records,
    sales: sales,
    today: today,
  );

  PharmacyBackup createBackup() => PharmacyBackup(
    createdAt: clock(),
    sourceRevision: snapshot.revision,
    settings: settings,
    records: snapshot.records,
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
      final currentRevision = snapshot.records[record.id]?.revision ?? 0;
      restored.add(
        Medicine.fromJson({
          ...record.toJson(),
          'revision': currentRevision > record.revision
              ? currentRevision + 1
              : record.revision + 1,
        }),
      );
    }
    for (final record in snapshot.records.values) {
      if (!review.backup.records.containsKey(record.id) && !record.archived) {
        restored.add(
          archiveMedicine(
            record,
            reason: 'Not present in restored backup',
            at: restoreStartedAt,
          ),
        );
      }
    }
    await _commit(
      InventoryMutation(
        expectedRevision: review.currentRevision,
        label:
            'Restored backup · ${review.activeMedicines} active medicines · ${review.sales} sales',
        upserts: restored,
        upsertSales: review.backup.sales.values.toList(),
        removeSaleIds: snapshot.sales.keys
            .where((id) => !review.backup.sales.containsKey(id))
            .toList(),
        settings: review.backup.settings,
        soldValueOverride: review.backup.soldValue,
        unknownSoldOverride: review.backup.unknownSold,
      ),
    );
  }

  AiPlan review(String input) => parseAiPlan(
    input,
    snapshot.records,
    snapshot.revision,
    snapshot.receipts,
    clock(),
  );

  Future<AiPlan> reviewAsync(String input) => compute(_parseReview, {
    'input': input,
    'records': snapshot.records,
    'revision': snapshot.revision,
    'receipts': snapshot.receipts,
    'now': clock(),
  });

  void cancelAi() {
    _cancelAi = true;
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
      final changes = <Medicine>[];
      for (var start = 0; start < plan.changes.length; start += 25) {
        if (_cancelAi || _disposed) {
          throw StateError('Cancelled. No inventory changes were saved.');
        }
        for (var i = start; i < plan.changes.length && i < start + 25; i++) {
          if (selection.contains(i)) {
            changes.add(Medicine.fromJson(plan.changes[i].after.toJson()));
          }
        }
        preparedActions = (start + 25).clamp(0, plan.changes.length);
        _emit();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (_cancelAi || _disposed) {
        throw StateError('Cancelled. No inventory changes were saved.');
      }
      await _commit(
        InventoryMutation(
          expectedRevision: plan.baseRevision,
          label: 'AI: applied ${changes.length} reviewed changes',
          upserts: changes,
          requestId: plan.requestId,
        ),
      );
    } finally {
      aiPreparing = false;
      _emit();
    }
  }

  Future<List<SearchHit>> search(String raw, SearchScope scope) async {
    final data = records.toList();
    final selectedSettings = settings;
    final date = today;
    // Isolate.run transfers the result; widgets bind it to their request generation.
    if (kIsWeb || !backgroundSearch) {
      if (_webRevision != snapshot.revision) {
        _webSearch = MedicineSearch(data);
        _webRevision = snapshot.revision;
      }
      return _webSearch!.search(
        raw,
        scope,
        selectedSettings,
        date,
        limit: raw.trim().isEmpty ? 100000 : 150,
      );
    }
    return _searchWorker.search(
      data,
      snapshot.revision,
      raw,
      scope,
      selectedSettings,
      date,
    );
  }

  /// Read-only fuzzy lookup over Removed stock. This is a projection over the
  /// same authoritative Medicine objects, not a second database. The native
  /// path uses the existing background search isolate and builds the archive
  /// index only when this feature is actually opened.
  Future<List<SearchHit>> searchArchived(String raw) async {
    final data = records.toList();
    final date = today;
    if (kIsWeb || !backgroundSearch) {
      if (_webArchivedRevision != snapshot.revision) {
        _webArchivedSearch = MedicineSearch(
          data.where((medicine) => medicine.archived),
          includeArchived: true,
        );
        _webArchivedRevision = snapshot.revision;
      }
      return _webArchivedSearch!.searchArchived(
        raw,
        date,
        limit: raw.trim().isEmpty ? 100000 : 150,
      );
    }
    return _searchWorker.searchArchived(data, snapshot.revision, raw, date);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final initializing = _initializing;
    _searchWorker.close();
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
