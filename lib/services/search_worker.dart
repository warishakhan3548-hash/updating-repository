import 'dart:async';
import 'dart:isolate';

import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/search.dart';

List<Medicine> _orderedActiveRecords(
  List<Medicine> records,
  SearchScope scope,
  WarningSettings settings,
  DateTime today,
) {
  final visible = records
      .where((medicine) => inScope(medicine, scope, settings, today))
      .toList(growable: false)
    ..sort((a, b) => expiryOrder(a, b, today));
  return visible;
}

List<Medicine> _orderedArchivedRecords(List<Medicine> records) {
  final visible = records
      .where((medicine) => medicine.archived)
      .toList(growable: false)
    ..sort(archivedOrder);
  return visible;
}

List<SearchHit> _browseWindow(
  List<Medicine> records,
  int limit,
  String reason,
) {
  final boundedLimit = limit < 1
      ? 1
      : limit > 100000
      ? 100000
      : limit;
  return records
      .take(boundedLimit)
      .map((medicine) => SearchHit(medicine.id, 1, reason, ''))
      .toList(growable: false);
}

void _searchEntry(SendPort main) {
  final receive = ReceivePort();
  main.send(receive.sendPort);
  MedicineSearch? engine;
  MedicineSearch? archivedEngine;
  List<Medicine>? indexedRecords;
  List<Medicine>? activeBrowseRecords;
  String activeBrowseKey = '';
  List<Medicine>? archivedBrowseRecords;
  var revision = -1;
  receive.listen((dynamic raw) {
    final message = raw as Map;
    final id = message['id'] as int;
    try {
      final kind = message['kind'] as String;
      if (kind == 'index') {
        indexedRecords = (message['records'] as List).cast<Medicine>();
        // Opening Stock with an empty query is a browse operation, not a fuzzy
        // search. Keep authoritative records ready in the worker but defer the
        // expensive token/trigram/delete indexes until a real query arrives.
        engine = null;
        archivedEngine = null;
        activeBrowseRecords = null;
        activeBrowseKey = '';
        archivedBrowseRecords = null;
        revision = message['revision'] as int;
        main.send({'id': id, 'result': true});
      } else if (kind == 'reuseIndex') {
        if (indexedRecords == null) {
          throw StateError('Search dataset changed. Retry this search.');
        }
        // Stock-only facts (quantity, price, row revision) do not participate
        // in search/status projection. The main isolate already proved those
        // fields are unchanged, so any existing fuzzy index stays valid.
        revision = message['revision'] as int;
        main.send({'id': id, 'result': true});
      } else if (kind == 'ensureSearchIndex') {
        if (indexedRecords == null || revision != message['revision']) {
          throw StateError('Search dataset changed. Retry this search.');
        }
        final built = engine == null;
        engine ??= MedicineSearch(indexedRecords!);
        main.send({'id': id, 'result': built});
      } else {
        if (indexedRecords == null || revision != message['revision']) {
          throw StateError('Search dataset changed. Retry this search.');
        }
        if (kind == 'browseActive') {
          final scope = message['scope'] as SearchScope;
          final settings = message['settings'] as WarningSettings;
          final today = message['today'] as DateTime;
          final nextBrowseKey =
              '${scope.index}:${settings.shortDays}:${settings.months}:${dateText(today)}';
          if (activeBrowseRecords == null ||
              activeBrowseKey != nextBrowseKey) {
            activeBrowseRecords = _orderedActiveRecords(
              indexedRecords!,
              scope,
              settings,
              today,
            );
            activeBrowseKey = nextBrowseKey;
          }
          main.send({
            'id': id,
            'result': _browseWindow(
              activeBrowseRecords!,
              message['limit'] as int,
              'Inventory',
            ),
          });
        } else if (kind == 'browseArchived') {
          archivedBrowseRecords ??= _orderedArchivedRecords(indexedRecords!);
          main.send({
            'id': id,
            'result': _browseWindow(
              archivedBrowseRecords!,
              message['limit'] as int,
              'Removed stock',
            ),
          });
        } else if (kind == 'searchArchived') {
          final query = message['query'] as String;
          if (query.trim().isEmpty) {
            throw StateError(
              'Removed-stock browse must use the browse operation.',
            );
          }
          archivedEngine ??= MedicineSearch(
            indexedRecords!.where((medicine) => medicine.archived),
            includeArchived: true,
          );
          main.send({
            'id': id,
            'result': archivedEngine!.searchArchived(
              query,
              message['today'] as DateTime,
              limit: message['limit'] as int,
            ),
          });
        } else if (kind == 'search') {
          final query = message['query'] as String;
          if (query.trim().isEmpty) {
            throw StateError('Inventory browse must use the browse operation.');
          }
          if (engine == null) {
            throw StateError('Search index is not ready. Retry this search.');
          }
          main.send({
            'id': id,
            'result': engine!.search(
              query,
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

class _SearchWorkerTransportFailure implements Exception {
  const _SearchWorkerTransportFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One restartable actor session.
///
/// Search errors produced by the domain engine are ordinary request failures and
/// keep the actor alive. Isolate exit/protocol/startup failures are transport
/// failures: every borrower is settled, the actor is retired, and SearchWorker
/// may create one fresh session for the same queued operation.
class _SearchWorkerSession {
  final ReceivePort _receive = ReceivePort();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Map<int, Completer<dynamic>> _pending = {};

  Isolate? _isolate;
  SendPort? _port;
  StreamSubscription<dynamic>? _subscription;
  bool _alive = true;
  int _id = 0;

  bool get alive => _alive;

  Future<void> start() async {
    if (!_alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search session is unavailable.',
      );
    }
    _subscription = _receive.listen(_onMessage);
    try {
      _isolate = await Isolate.spawn(
        _searchEntry,
        _receive.sendPort,
        onExit: _receive.sendPort,
        onError: _receive.sendPort,
      );
      _port = await _ready.future.timeout(const Duration(seconds: 8));
    } catch (error) {
      final failure = error is _SearchWorkerTransportFailure
          ? error
          : _SearchWorkerTransportFailure(
              'Background search could not start: $error',
            );
      _fail(failure);
      throw failure;
    }
  }

  void _onMessage(dynamic value) {
    if (!_alive) return;
    if (value is SendPort) {
      if (!_ready.isCompleted) _ready.complete(value);
      return;
    }
    if (value == null || value is List) {
      _fail(
        const _SearchWorkerTransportFailure(
          'Background search stopped unexpectedly.',
        ),
      );
      return;
    }
    if (value is! Map) {
      _fail(
        const _SearchWorkerTransportFailure(
          'Background search returned an invalid transport message.',
        ),
      );
      return;
    }

    final result = Map<dynamic, dynamic>.from(value);
    final id = result['id'];
    if (id is! int) {
      _fail(
        const _SearchWorkerTransportFailure(
          'Background search returned an invalid request ID.',
        ),
      );
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null || pending.isCompleted) return;
    final error = result['error'];
    if (error is String) {
      pending.completeError(StateError(error));
      return;
    }
    if (!result.containsKey('result')) {
      _fail(
        const _SearchWorkerTransportFailure(
          'Background search returned an incomplete response.',
        ),
      );
      return;
    }
    pending.complete(result['result']);
  }

  Future<dynamic> request(Map<String, dynamic> message) async {
    if (!_alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search session stopped.',
      );
    }
    final port = _port ?? await _ready.future;
    if (!_alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search session stopped.',
      );
    }
    final id = ++_id;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    port.send({...message, 'id': id});
    return completer.future;
  }

  void _fail(Object error) {
    if (!_alive) return;
    _alive = false;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port = null;
    _receive.close();
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  void close() => _fail(
    const _SearchWorkerTransportFailure('Background search closed.'),
  );
}

class SearchWorker {
  _SearchWorkerSession? _session;
  Future<_SearchWorkerSession>? _starting;
  final Map<String, Medicine> _indexedRecordRefs = {};
  int _revision = -1;
  int _indexBuilds = 0;
  bool _closed = false;
  Future<void> _queue = Future.value();

  /// Number of expensive fuzzy-index builds, not ordinary empty-query browse
  /// passes. Diagnostic only; it never participates in search decisions.
  int get debugIndexBuilds => _indexBuilds;

  Future<_SearchWorkerSession> _worker() {
    if (_closed) {
      return Future.error(StateError('Search closed.'));
    }
    final current = _session;
    if (current != null && current.alive) return Future.value(current);
    if (current != null) _retire(current);
    final starting = _starting;
    if (starting != null) return starting;

    late final Future<_SearchWorkerSession> operation;
    operation = _startWorker().whenComplete(() {
      if (identical(_starting, operation)) _starting = null;
    });
    _starting = operation;
    return operation;
  }

  Future<_SearchWorkerSession> _startWorker() async {
    final session = _SearchWorkerSession();
    await session.start();
    if (_closed) {
      session.close();
      throw StateError('Search closed.');
    }
    _session = session;
    _revision = -1;
    _indexedRecordRefs.clear();
    return session;
  }

  void _retire(_SearchWorkerSession session) {
    session.close();
    if (!identical(_session, session)) return;
    _session = null;
    _revision = -1;
    _indexedRecordRefs.clear();
  }

  bool _canReuseIndex(List<Medicine> records) {
    if (_revision < 0 || _indexedRecordRefs.length != records.length) {
      return false;
    }
    final replacements = <Medicine>[];
    for (final record in records) {
      final indexed = _indexedRecordRefs[record.id];
      if (indexed == null) return false;
      if (identical(indexed, record)) continue;
      if (!sameSearchProjection(indexed, record)) return false;
      replacements.add(record);
    }
    // Quantity, cost, row revision and other non-search facts may change very
    // frequently during dispensing. Update only those object witnesses while
    // retaining the expensive token/fuzzy index built from identical search
    // facts. The worker never returns Medicine objects, only stable stock IDs.
    for (final record in replacements) {
      _indexedRecordRefs[record.id] = record;
    }
    return true;
  }

  Future<_SearchWorkerSession> _ensureIndex(
    List<Medicine> records,
    int revision,
  ) async {
    final session = await _worker();
    if (_revision == revision) return session;
    if (_canReuseIndex(records)) {
      await session.request({
        'kind': 'reuseIndex',
        'revision': revision,
      });
      if (!session.alive) {
        throw const _SearchWorkerTransportFailure(
          'Background search stopped while rebinding its index.',
        );
      }
      _revision = revision;
      return session;
    }
    await session.request({
      'kind': 'index',
      'records': records,
      'revision': revision,
    });
    if (!session.alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search stopped while indexing.',
      );
    }
    _revision = revision;
    _indexedRecordRefs
      ..clear()
      ..addEntries(records.map((record) => MapEntry(record.id, record)));
    return session;
  }

  Future<void> _ensureSearchIndex(
    _SearchWorkerSession session,
    int revision,
  ) async {
    final built = await session.request({
      'kind': 'ensureSearchIndex',
      'revision': revision,
    });
    if (!session.alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search stopped while preparing its fuzzy index.',
      );
    }
    if (built == true) _indexBuilds++;
  }

  Future<T> _withTransportRecovery<T>(Future<T> Function() operation) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await operation();
      } on _SearchWorkerTransportFailure {
        final session = _session;
        if (session != null) _retire(session);
        if (_closed || attempt == 1) rethrow;
      }
    }
    throw StateError('Background search recovery failed.');
  }

  Future<List<SearchHit>> browseActive(
    List<Medicine> records,
    int revision,
    SearchScope scope,
    WarningSettings settings,
    DateTime today, {
    required int limit,
  }) {
    final result = _queue.then(
      (_) => _withTransportRecovery(() async {
        final session = await _ensureIndex(records, revision);
        final response = await session.request({
          'kind': 'browseActive',
          'revision': revision,
          'scope': scope,
          'settings': settings,
          'today': today,
          'limit': limit,
        });
        return (response as List).cast<SearchHit>();
      }),
    );
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<List<SearchHit>> search(
    List<Medicine> records,
    int revision,
    String query,
    SearchScope scope,
    WarningSettings settings,
    DateTime today,
  ) {
    if (query.trim().isEmpty) {
      return Future.error(
        ArgumentError.value(
          query,
          'query',
          'Use browseActive for an empty inventory query.',
        ),
      );
    }
    final result = _queue.then(
      (_) => _withTransportRecovery(() async {
        final session = await _ensureIndex(records, revision);
        await _ensureSearchIndex(session, revision);
        final response = await session.request({
          'kind': 'search',
          'revision': revision,
          'query': query,
          'scope': scope,
          'settings': settings,
          'today': today,
          'limit': 150,
        });
        return (response as List).cast<SearchHit>();
      }),
    );
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<List<SearchHit>> browseArchived(
    List<Medicine> records,
    int revision, {
    required int limit,
  }) {
    final result = _queue.then(
      (_) => _withTransportRecovery(() async {
        final session = await _ensureIndex(records, revision);
        final response = await session.request({
          'kind': 'browseArchived',
          'revision': revision,
          'limit': limit,
        });
        return (response as List).cast<SearchHit>();
      }),
    );
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<List<SearchHit>> searchArchived(
    List<Medicine> records,
    int revision,
    String query,
    DateTime today,
  ) {
    if (query.trim().isEmpty) {
      return Future.error(
        ArgumentError.value(
          query,
          'query',
          'Use browseArchived for an empty removed-stock query.',
        ),
      );
    }
    final result = _queue.then(
      (_) => _withTransportRecovery(() async {
        final session = await _ensureIndex(records, revision);
        final response = await session.request({
          'kind': 'searchArchived',
          'revision': revision,
          'query': query,
          'today': today,
          'limit': 150,
        });
        return (response as List).cast<SearchHit>();
      }),
    );
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final session = _session;
    _session = null;
    session?.close();
    _revision = -1;
    _indexedRecordRefs.clear();
  }
}
