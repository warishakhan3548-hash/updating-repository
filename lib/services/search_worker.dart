import 'dart:async';
import 'dart:isolate';

import '../domain/medicine.dart';
import '../domain/search.dart';
import '../domain/inventory.dart';

void _searchEntry(SendPort main) {
  final receive = ReceivePort();
  main.send(receive.sendPort);
  MedicineSearch? engine;
  MedicineSearch? archivedEngine;
  List<Medicine>? indexedRecords;
  var revision = -1;
  receive.listen((dynamic raw) {
    final message = raw as Map;
    final id = message['id'] as int;
    try {
      final kind = message['kind'] as String;
      if (kind == 'index') {
        indexedRecords = (message['records'] as List).cast<Medicine>();
        engine = MedicineSearch(indexedRecords!);
        // Removed history is intentionally indexed lazily. Normal medicine
        // search stays as small and hot as before even when years of archived
        // stock are retained for recovery/audit.
        archivedEngine = null;
        revision = message['revision'] as int;
        main.send({'id': id, 'result': true});
      } else {
        if (engine == null ||
            indexedRecords == null ||
            revision != message['revision']) {
          throw StateError('Search index changed. Retry this search.');
        }
        if (kind == 'searchArchived') {
          archivedEngine ??= MedicineSearch(
            indexedRecords!.where((medicine) => medicine.archived),
            includeArchived: true,
          );
          main.send({
            'id': id,
            'result': archivedEngine!.searchArchived(
              message['query'] as String,
              message['today'] as DateTime,
              limit: message['limit'] as int,
            ),
          });
        } else if (kind == 'search') {
          main.send({
            'id': id,
            'result': engine!.search(
              message['query'] as String,
              message['scope'] as SearchScope,
              message['settings'] as WarningSettings,
              message['today'] as DateTime,
              limit: message['limit'] as int,
            ),
          });
        } else {
          throw StateError('Unknown search operation.');
        }
      }
    } catch (e) {
      main.send({'id': id, 'error': e.toString()});
    }
  });
}

class SearchWorker {
  final _receive = ReceivePort();
  final _ready = Completer<SendPort?>();
  final Map<int, Completer<dynamic>> _pending = {};
  Isolate? _isolate;
  int _id = 0, _revision = -1;
  bool _closed = false;
  late final Future<void> _start = _initialize();
  Future<void> _queue = Future.value();

  Future<void> _initialize() async {
    if (_closed) return;
    _receive.listen((dynamic value) {
      if (value is SendPort) {
        if (!_ready.isCompleted) _ready.complete(value);
        return;
      }
      if (value == null || value is List) {
        close(); // Worker exit/error must settle callers, including startup.
        return;
      }
      final result = value as Map;
      final pending = _pending.remove(result['id']);
      if (pending == null) return;
      if (result.containsKey('error')) {
        pending.completeError(StateError(result['error'] as String));
      } else {
        pending.complete(result['result']);
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _searchEntry,
        _receive.sendPort,
        onExit: _receive.sendPort,
        onError: _receive.sendPort,
      );
    } catch (_) {
      close();
      rethrow;
    }
    if (_closed) _isolate?.kill(priority: Isolate.immediate);
  }

  Future<dynamic> _request(Map<String, dynamic> message) async {
    if (_closed) throw StateError('Search closed.');
    final port = await _ready.future;
    if (_closed || port == null) throw StateError('Search closed.');
    final id = ++_id;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    port.send({...message, 'id': id});
    return completer.future;
  }

  Future<void> _ensureIndex(List<Medicine> records, int revision) async {
    await _start;
    if (_revision == revision) return;
    await _request({'kind': 'index', 'records': records, 'revision': revision});
    _revision = revision;
  }

  Future<List<SearchHit>> search(
    List<Medicine> records,
    int revision,
    String query,
    SearchScope scope,
    WarningSettings settings,
    DateTime today,
  ) {
    final result = _queue.then((_) async {
      await _ensureIndex(records, revision);
      final response = await _request({
        'kind': 'search',
        'revision': revision,
        'query': query,
        'scope': scope,
        'settings': settings,
        'today': today,
        'limit': query.trim().isEmpty ? 100000 : 150,
      });
      return (response as List).cast<SearchHit>();
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<List<SearchHit>> searchArchived(
    List<Medicine> records,
    int revision,
    String query,
    DateTime today,
  ) {
    final result = _queue.then((_) async {
      await _ensureIndex(records, revision);
      final response = await _request({
        'kind': 'searchArchived',
        'revision': revision,
        'query': query,
        'today': today,
        'limit': query.trim().isEmpty ? 100000 : 150,
      });
      return (response as List).cast<SearchHit>();
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.complete(null);
    _isolate?.kill(priority: Isolate.immediate);
    _receive.close();
    for (final pending in _pending.values) {
      pending.completeError(StateError('Search closed.'));
    }
    _pending.clear();
  }
}
