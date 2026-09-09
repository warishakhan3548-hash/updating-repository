import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/inventory_database.dart';
import '../domain/ai_protocol.dart';
import '../domain/backup.dart';
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
  MedicineSearch? _webSearch;
  int _webRevision = -1;
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
    if (quantity < 1 || quantity > 100000000) {
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
        upserts: [
          m.patch({'archived': true}),
        ],
      ),
    );
  }

  Future<void> archiveAll({int? expectedRevision}) => _commit(
    InventoryMutation(
      expectedRevision: expectedRevision ?? snapshot.revision,
      label: 'Removed all inventory',
      upserts: records
          .where((m) => !m.archived)
          .map((m) => m.patch({'archived': true}))
          .toList(),
    ),
  );
  Future<void> restoreArchived(String id) async {
    final m = snapshot.records[id];
    if (m == null || !m.archived) return;
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Restored ${m.name}',
        upserts: [
          m.patch({'archived': false}),
        ],
      ),
    );
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
        restored.add(record.patch({'archived': true}));
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
    if (plan.baseRevision != snapshot.revision)
      throw StateError(
        'Inventory changed after review. Review a fresh snapshot.',
      );
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
        if (_cancelAi || _disposed)
          throw StateError('Cancelled. No inventory changes were saved.');
        for (var i = start; i < plan.changes.length && i < start + 25; i++) {
          if (selection.contains(i))
            changes.add(Medicine.fromJson(plan.changes[i].after.toJson()));
        }
        preparedActions = (start + 25).clamp(0, plan.changes.length);
        _emit();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (_cancelAi || _disposed)
        throw StateError('Cancelled. No inventory changes were saved.');
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
