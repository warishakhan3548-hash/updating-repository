import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/inventory_database.dart';
import '../domain/ai_protocol.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/search.dart';
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
  Future<void> _writes = Future.value();
  final _searchWorker = SearchWorker();
  MedicineSearch? _webSearch;
  int _webRevision = -1;
  DateTime get today => civilDay(clock());
  WarningSettings get settings => snapshot.settings;
  Iterable<Medicine> get records => snapshot.records.values;
  InventoryStats get stats => InventoryStats(records, today);

  Future<void> initialize() async {
    snapshot = await storage.load();
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

  Future<void> _commit(InventoryMutation mutation) {
    final result = _writes.then((_) async {
      if (_disposed) throw StateError('App is closed.');
      snapshot = await storage.commit(mutation);
      _emit();
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> save(Medicine record, {required int expectedRevision}) =>
      _commit(
        InventoryMutation(
          expectedRevision: expectedRevision,
          label: snapshot.records.containsKey(record.id)
              ? 'Edited ${record.name}'
              : 'Added ${record.name}',
          upserts: [record],
        ),
      );
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
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Marked ${m.name} sold',
        upserts: [
          m.patch({
            'sold': true,
            'quantity': 0,
            'soldAt': clock().toIso8601String(),
            'soldQuantity': m.quantity,
            'soldUnitPricePaise': m.unitPricePaise,
          }),
        ],
      ),
    );
  }

  Future<void> archive(String id, String reason) async {
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

  Future<void> archiveAll() => _commit(
    InventoryMutation(
      expectedRevision: snapshot.revision,
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

  bool get canUndo =>
      snapshot.events.isNotEmpty &&
      snapshot.events.first['revision'] == snapshot.revision &&
      snapshot.events.first['undoable'] == true &&
      snapshot.events.first['undone'] != true;
  Future<void> undo() async {
    if (!canUndo) throw StateError('No current change is available to undo.');
    final event = snapshot.events.first;
    final before = Map<String, dynamic>.from(event['before'] as Map);
    final upserts = <Medicine>[], removes = <String>[];
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
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Undo: ${event['label']}',
        upserts: upserts,
        removeIds: removes,
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
    today: today,
  );
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
    if (selected.isEmpty) return;
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
          if (selected.contains(i))
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
    _disposed = true;
    _searchWorker.close();
    _midnight?.cancel();
    _cancelAi = true;
    unawaited(_writes.whenComplete(storage.close));
    super.dispose();
  }
}

AiPlan _parseReview(Map<String, dynamic> data) => parseAiPlan(
  data['input'] as String,
  data['records'] as Map<String, Medicine>,
  data['revision'] as int,
  data['receipts'] as Set<String>,
  data['now'] as DateTime,
);
