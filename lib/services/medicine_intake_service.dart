import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/medicine.dart';
import '../domain/local_scan_request.dart';
import '../domain/medicine_intake.dart';
import '../domain/medicine_evidence_normalization.dart';
import '../domain/medicine_resolution_v2.dart';
import '../domain/medicine_understanding.dart';
import 'canonical_medicine_catalog_service.dart';
import 'local_ai_service.dart';
import 'local_brain_route_policy.dart';
import 'media_import_service.dart';
import 'offline_recognition_memory_service.dart';
import 'scan_service.dart';

class MedicineIntakeEnqueueCancelled implements Exception {
  const MedicineIntakeEnqueueCancelled();
}

/// Persistent, bounded work queue shared by AI Hub and ordinary import.
/// Captures are acknowledged after private-file copy + SQLite job commit,
/// independently of OCR/LLM latency. Inventory is never written by this service.
class MedicineIntakeService extends ChangeNotifier with WidgetsBindingObserver {
  MedicineIntakeService._() {
    LocalAiService.instance.addListener(_modelChanged);
  }
  static final instance = MedicineIntakeService._();
  static const capacity = 250;
  static const _waitingForLocalAi =
      'Local AI is finishing another request. OCR is saved and AI refinement will resume automatically.';
  static const _retryLocalAiWhenIdle =
      'Local AI is busy. Saved scan will retry when the local lease is idle.';
  final _jobs = <MedicineIntakeJob>[];
  late final List<MedicineIntakeJob> _jobsView =
      UnmodifiableListView<MedicineIntakeJob>(_jobs);
  final _media = MediaImportService();
  Database? _database;
  Directory? _root;
  Future<void>? _initializing;
  Future<void> _intakeWrites = Future.value();
  final _workBarrier = MedicineIntakeWorkBarrier();
  final _scanRequests = <String, LocalScanRequest>{};
  bool _running = false, _appActive = true;
  bool _ready = false, _preferReasoning = false, _observingMemory = false;
  String persistenceError = '';
  Iterable<Medicine> Function()? _records;
  int Function()? _revision;
  int? _knowledgeRevision;
  List<MedicineKnowledgeEntry>? _knowledge;

  List<MedicineIntakeJob> get jobs => _jobsView;
  bool get full => _jobs.length >= capacity;
  bool get processing => _running;
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> attach(
    Iterable<Medicine> Function() records, {
    int Function()? revision,
  }) async {
    _records = records;
    _revision = revision;
    _knowledgeRevision = null;
    _knowledge = null;
    await initialize();
    _kick();
  }

  Future<void> initialize() =>
      _initializing ??= _initialize().catchError((Object e) {
        _ready = false;
        _initializing = null;
        throw e;
      });

  Future<void> _initialize() async {
    if (!supported) return;
    final support = await getApplicationSupportDirectory();
    _root = await Directory('${support.path}/medicine_intake')
        .create(recursive: true);
    _database = await openDatabase(
      '${_root!.path}/jobs.db',
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE jobs (id TEXT PRIMARY KEY, data TEXT NOT NULL, created INTEGER NOT NULL)',
        );
      },
    );
    final rows = await _database!.query(
      'jobs',
      orderBy: 'created ASC',
      limit: capacity + 1,
    );
    if (rows.length > capacity) {
      throw StateError('Intake queue exceeds capacity.');
    }
    final restored = <MedicineIntakeJob>[];
    for (final row in rows) {
      final raw = row['data'] as String;
      if (raw.length > 20000000) {
        throw StateError('Saved intake is too large.');
      }
      final job = MedicineIntakeJob.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (row['id'] != job.id) throw StateError('Saved capture ID mismatch.');
      if (job.status == 'processing') job.status = 'queued';
      // Validate recovered paths before allowing read/delete operations.
      if (job.path.isNotEmpty && job.path != _capturePath(job.id, job.kind)) {
        throw StateError('Saved intake contains an unexpected file path.');
      }
      restored.add(job);
    }
    // The capture queue is an offline deterministic capability and must never
    // depend on optional Local-AI settings/model-manifest health. A reasoning
    // route is initialized best-effort later by LocalBrainRoutePolicy only when
    // a capture actually owns an AI witness. Corrupt/unavailable model state can
    // therefore no longer prevent OCR jobs from being restored or accepted.
    _jobs
      ..clear()
      ..addAll(restored);
    await _cleanupOrphanedCaptureFiles(restored);
    if (!_observingMemory) {
      WidgetsBinding.instance.addObserver(this);
      _observingMemory = true;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _ready = true;
    for (final job in _jobs) {
      if (job.status == 'reasoning' && job.drafts.isNotEmpty)
        _scanRequestFor(job);
    }
    notifyListeners();
  }

  String _capturePath(String id, String kind) =>
      '${_root!.path}/$id.${kind == 'video' ? 'mp4' : 'jpg'}';

  Future<void> _cleanupOrphanedCaptureFiles(
    Iterable<MedicineIntakeJob> restored,
  ) async {
    final root = _root;
    if (root == null) return;
    final retained = restored
        .where((job) => job.path.isNotEmpty)
        .map((job) => job.path)
        .toSet();
    final captureName = RegExp(r'^[a-f0-9]{32}\.(?:jpg|mp4)$');
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File ||
            retained.contains(entity.path) ||
            !captureName.hasMatch(entity.uri.pathSegments.last)) {
          continue;
        }
        try {
          await entity.delete();
        } on FileSystemException {
          // A pre-checkpoint orphan is housekeeping only. Never make the
          // authoritative queue unavailable because Android temporarily refused
          // to delete an otherwise unreferenced private capture.
        }
      }
    } on FileSystemException {
      // Directory enumeration is best-effort for the same reason. Restored jobs
      // have already had their exact private paths validated above.
    }
  }

  Future<void> _releaseProcessedSource(MedicineIntakeJob job) async {
    if (job.path.isEmpty) return;
    if (job.path != _capturePath(job.id, job.kind)) {
      throw StateError('Capture source path changed unexpectedly.');
    }
    final source = File(job.path);
    try {
      if (await source.exists()) await source.delete();
      job.path = '';
    } on FileSystemException {
      // OCR/drafts are already durably checkpointed. Keep the validated path in
      // the row so Retry/Dismiss or a later launch can attempt cleanup again;
      // a housekeeping failure must never downgrade valid recognition to failed.
    }
  }

  Future<void> _persist(
    MedicineIntakeJob job, {
    bool insert = false,
    bool publish = true,
  }) async {
    final data = jsonEncode(job.toJson());
    if (data.length > 20000000) {
      throw StateError('Capture draft limit reached. Split this video.');
    }
    if (insert) {
      await _database!.insert('jobs', {
        'id': job.id,
        'data': data,
        'created': DateTime.now().microsecondsSinceEpoch,
      });
    } else {
      final changed = await _database!.update(
        'jobs',
        {'data': data},
        where: 'id=?',
        whereArgs: [job.id],
      );
      if (changed != 1) {
        throw StateError('Capture checkpoint could not be saved.');
      }
    }
    if (job.status == 'reasoning' && job.drafts.isNotEmpty) {
      _scanRequestFor(job);
    } else {
      _scanRequests.remove(job.id)?.close();
    }
    if (publish) notifyListeners();
  }

  LocalScanRequest _scanRequestFor(MedicineIntakeJob job) {
    final existing = _scanRequests[job.id];
    if (existing != null) return existing;
    late final LocalScanRequest request;
    request = LocalScanRequest(
      onTimeout: () {
        if (!identical(_scanRequests[job.id], request)) return;
        unawaited(
          continueWithDraft(job, timedOut: true).catchError((Object error) {
            persistenceError = 'Capture checkpoint needs attention: $error';
            notifyListeners();
          }),
        );
      },
    );
    _scanRequests[job.id] = request;
    return request;
  }

  /// Freeze the available draft before navigation, without waiting for optional
  /// inference. A scope revokes only this scan's lease; late results are ignored.
  ///
  /// Review is an actionable terminal state, so callers must not be released
  /// until that state is durably checkpointed. Re-checkpoint an already-frozen
  /// review as well: if an earlier SQLite write failed, a second Next tap retries
  /// the durability boundary instead of silently trusting memory-only state.
  Future<void> continueWithDraft(
    MedicineIntakeJob job, {
    bool timedOut = false,
  }) async {
    if (!_jobs.contains(job) || !job.canReview) return;
    final transitioned = job.finishOptionalReview(
      message: timedOut
          ? 'Local AI review timed out. Scanned details are ready to check.'
          : '',
    );
    if (transitioned) {
      _scanRequests.remove(job.id)?.close();
    }
    if (!job.terminal) return;

    await _enqueue(() async {
      if (!_jobs.contains(job)) {
        throw StateError('This saved capture is no longer available.');
      }
      if (!job.terminal) {
        throw StateError(
          'Capture review changed before its checkpoint could be saved.',
        );
      }
      await _persist(job, publish: false);
    });
    notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final future = _intakeWrites.then((_) => action());
    _intakeWrites = future.catchError((Object _) {});
    return future;
  }

  void _throwIfEnqueueCancelled(bool Function()? cancelled) {
    if (cancelled?.call() ?? false) {
      throw const MedicineIntakeEnqueueCancelled();
    }
  }

  Future<void> addFile(
    String path, {
    required String kind,
    required String title,
    bool Function()? cancelled,
  }) => _enqueue(() async {
    await initialize();
    _throwIfEnqueueCancelled(cancelled);
    if (!supported) {
      throw UnsupportedError('Capture queue requires the Android app.');
    }
    if (full) {
      throw StateError(
        'Review/dismiss some captures before adding more (limit $capacity).',
      );
    }
    if (kind != 'photo' && kind != 'video') {
      throw const FormatException('Invalid capture type.');
    }
    final local = LocalAiService.instance;
    final modelId = await LocalBrainRoutePolicy.captureModelId(local);
    _throwIfEnqueueCancelled(cancelled);
    final job = MedicineIntakeJob(
      id: intakeId(),
      kind: kind,
      title: title,
      modelId: modelId,
    );
    job.path = _capturePath(job.id, kind);
    var durable = false;
    try {
      final length = await File(path).length();
      final facts = await const MethodChannel('com.aaris.pharmacy/documents')
          .invokeMapMethod<String, dynamic>('localAiDeviceInfo');
      final free = facts?['freeStorage'];
      if (length <= 0 || (free is int && free < length + 128 * 1024 * 1024)) {
        throw StateError(
          'Not enough private storage to safely queue this capture. Original file is unchanged.',
        );
      }
      _throwIfEnqueueCancelled(cancelled);
      await File(path).copy(job.path);
      if (await File(job.path).length() != length) {
        throw StateError(
          'Incomplete capture copy. Please select the original again.',
        );
      }
      _throwIfEnqueueCancelled(cancelled);
      await _persist(job, insert: true, publish: false);
      durable = true;
      if (cancelled?.call() ?? false) {
        var rolledBack = false;
        try {
          final deleted = await _database!.delete(
            'jobs',
            where: 'id=?',
            whereArgs: [job.id],
          );
          rolledBack = deleted == 1;
        } catch (_) {}
        if (rolledBack) {
          durable = false;
          throw const MedicineIntakeEnqueueCancelled();
        }
      }
      _jobs.add(job);
    } catch (_) {
      if (!durable) {
        final copy = File(job.path);
        if (await copy.exists()) await copy.delete();
      }
      rethrow;
    }
    notifyListeners();
    _kick();
  });

  Future<void> addEvidence(
    List<MedicineFrameEvidence> evidence, {
    String title = 'Camera scan',
  }) => _enqueue(() async {
    await initialize();
    if (!supported) {
      throw UnsupportedError('Capture queue requires the Android app.');
    }
    if (full ||
        evidence.isEmpty ||
        evidence.length > maxMedicineEvidenceFrames) {
      throw StateError('Empty capture or intake capacity exceeded.');
    }
    final local = LocalAiService.instance;
    final modelId = await LocalBrainRoutePolicy.captureModelId(local);
    final job = MedicineIntakeJob(
      id: intakeId(),
      kind: 'evidence',
      title: title,
      evidence: List.of(evidence),
      modelId: modelId,
    );
    await _persist(job, insert: true, publish: false);
    _jobs.add(job);
    notifyListeners();
    _kick();
  });

  @override
  void didHaveMemoryPressure() {
    // Memory pressure is a resource signal, not a user workflow state. The
    // LocalAiService owns runtime shedding and safely unloads its model after an
    // active lease completes. Intake only drops rebuildable identity knowledge;
    // durable OCR/video checkpoints continue automatically without a Resume gate.
    _knowledge = null;
    _knowledgeRevision = null;
    notifyListeners();
    if (_appActive) _kick();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;

    // Identity-only derived knowledge can be rebuilt cheaply after resume and
    // need not occupy memory while the app is backgrounded. Foregrounding the
    // app always restarts any durable queued work automatically.
    if (!active) {
      _knowledge = null;
      _knowledgeRevision = null;
      notifyListeners();
      return;
    }

    notifyListeners();
    _kick();
  }

  void _modelChanged() {
    if (!LocalAiService.instance.busy) _kick();
  }

  void _kick() {
    if (_running ||
        !_appActive ||
        !_ready ||
        _database == null ||
        _records == null ||
        persistenceError.isNotEmpty) {
      return;
    }
    unawaited(
      _pump().catchError((Object e) {
        persistenceError = 'Capture queue needs attention: $e';
        notifyListeners();
      }),
    );
  }

  Future<MedicineUnderstandingResult> _understand(
    List<MedicineFrameEvidence> frames,
  ) async {
    frames = normalizeMedicineReviewEvidence(frames);
    final revision = _revision?.call();
    if (_knowledge == null ||
        revision == null ||
        revision != _knowledgeRevision) {
      _knowledge = medicineKnowledgeFromRecords(_records!());
      _knowledgeRevision = revision;
    }

    // A bounded correction memory enriches only matching current local
    // identities and fails open. Raw OCR documents are never stored in it.
    final knowledge = await OfflineRecognitionMemoryService.instance
        .enrichKnowledge(_knowledge!, frames);

    // Tier-2 master knowledge is optional and queried before isolate work so a
    // very large canonical catalogue never crosses the isolate boundary. The
    // catalogue service is fail-open: empty/corrupt/unavailable knowledge simply
    // leaves Tier-1 pharmacist-reviewed shop memory as the authoritative fallback.
    final catalogue = await CanonicalMedicineCatalogService.instance
        .candidatesForEvidence(frames);

    return MedicineUnderstandingResult.fromMessage(
      await compute(understandMedicineEvidenceV2Message, <String, Object?>{
        'evidence': frames.map((e) => e.toMessage()).toList(),
        'knowledge': knowledge
            .map((k) => k.toMessage())
            .toList(growable: false),
        'catalog': catalogue.map((value) => value.toMessage()).toList(),
      }),
    );
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    try {
      while (_appActive) {
        // OCR/capture work has priority, so fast photos are turned into durable
        // text before slower semantic reasoning monopolizes the native model.
        final local = LocalAiService.instance;
        final job = nextMedicineIntakeJob(
          _jobs,
          allowReasoning: !local.busy && !local.transferring,
          preferReasoning: _preferReasoning,
        );
        if (job == null) break;
        _workBarrier.begin(job.id);
        try {
          try {
            if (job.status == 'reasoning') {
              _preferReasoning = false;
              await _reason(job);
            } else {
              _preferReasoning = true;
              job.status = 'processing';
              await _persist(job);
              if (job.kind == 'video') {
                await _videoStep(job);
              } else {
                await _photoStep(job);
              }
            }
            await _persist(job);
          } catch (e) {
            job.status = 'failed';
            job.error = e.toString();
            await _persist(job);
          }
        } finally {
          // Terminal state may have been checkpointed earlier by the OCR/video
          // step. Release only after the worker's final row write/cleanup path is
          // completely finished so Retry/Dismiss cannot delete beneath it.
          _workBarrier.finish(job.id);
        }
      }
    } finally {
      _running = false;
      notifyListeners();

      // Close the classic lost-wakeup window: a foreground chat can release the
      // Local AI after this pump observed it as busy but before its listener was
      // able to restart us. Re-check only when the lease is now free, and only
      // restart when a non-terminal job is actually eligible, so there is no
      // idle spin when the queue contains review/failed cards only.
      final local = LocalAiService.instance;
      final shouldRestart =
          _appActive &&
          _ready &&
          persistenceError.isEmpty &&
          !local.busy &&
          !local.transferring &&
          nextMedicineIntakeJob(
                _jobs,
                allowReasoning: true,
                preferReasoning: _preferReasoning,
              ) !=
              null;
      if (shouldRestart) _kick();
    }
  }

  void _ocrFinished(MedicineIntakeJob job) {
    job.status = job.modelId == null ? 'review' : 'reasoning';
    if (job.drafts.isEmpty) {
      job.status = 'failed';
      job.error = job.kind == 'video'
          ? 'No medicine could be read. Retry the video or record closer, steadier views of each pack.'
          : 'No medicine could be read. Take a closer, steadier photo.';
    }
  }

  Future<void> _photoStep(MedicineIntakeJob job) async {
    if (job.kind == 'photo') {
      final vision = MedicineVisionService();
      try {
        job.evidence = [await vision.analyzeFile(job.path, source: job.title)];
      } finally {
        await vision.close();
      }
    }
    job.drafts = (await _understand(job.evidence)).drafts;
    _ocrFinished(job);
    // Persist OCR before deleting source, so a killed process can resume from
    // text. The private image is retained on recognition failure for retry.
    await _persist(job);
    if (job.status != 'failed') {
      await _releaseProcessedSource(job);
    }
  }

  Future<void> _videoStep(MedicineIntakeJob job) async {
    final window = await _media.sampleVideoWindow(job.path, job.cursorMs);
    if (window.nextStartMs <= job.cursorMs && !window.complete) {
      throw StateError('Video sampler did not advance.');
    }
    final vision = MedicineVisionService();
    final evidence = List<MedicineFrameEvidence>.of(job.evidence);
    var unreadable = window.unreadableFrames;
    if (window.frames.isEmpty && unreadable == 0) unreadable = 1;
    try {
      for (final frame in window.frames) {
        try {
          final scanned = await vision.analyzeFile(
            frame.path,
            source: job.title,
            sequence: frame.sequence,
            timestampMs: frame.timestampMs,
            quality: frame.quality,
          );
          if (scanned.text.trim().isEmpty && scanned.allBarcodes.isEmpty) {
            unreadable++;
          } else {
            evidence.add(scanned);
          }
        } catch (_) {
          unreadable++;
        } finally {
          await _media.cleanup([frame.path]);
        }
      }
    } finally {
      try {
        await vision.close();
      } finally {
        await _media.cleanup(window.frames.map((f) => f.path));
      }
    }
    final result = evidence.isEmpty
        ? const MedicineUnderstandingResult(drafts: [])
        : await _understand(evidence);
    final grouped = finishMedicineVideoWindow(
      evidence,
      result.drafts,
      isLast: window.complete,
    );
    if (job.drafts.length + grouped.completed.length > 500) {
      throw StateError(
        'This video exceeds 500 draft objects. Split it into smaller videos. Completed drafts are retained.',
      );
    }
    job.drafts.addAll(grouped.completed);
    job.evidence = grouped.carry;
    job.cursorMs = window.nextStartMs;
    job.durationMs = window.durationMs;
    job.unreadableFrames += unreadable;
    if (window.complete) {
      _ocrFinished(job);
    } else {
      job.status = 'queued';
    }
    // Cursor + completed drafts + unresolved carry commit together.
    await _persist(job);
    if (window.complete &&
        job.status != 'failed' &&
        job.unreadableFrames == 0) {
      await _releaseProcessedSource(job);
    }
  }

  bool _localLeaseContention(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('local ai is busy') ||
        message.contains('runtime is unavailable or still processing') ||
        message.contains('runtime is busy or closing') ||
        message.contains('runtime is still processing a failed model load');
  }

  bool _recoverableLocalTransportFailure(Object error) {
    if (error is FormatException || error is ArgumentError) return false;
    final message = error.toString().toLowerCase();
    if (message.contains('cancel') ||
        message.contains('busy') ||
        message.contains('select a local model') ||
        message.contains('selected model is missing') ||
        message.contains('model file is incomplete') ||
        message.contains('invalid model') ||
        message.contains('unsupported context')) {
      return false;
    }
    return message.contains('runtime') ||
        message.contains('transport') ||
        message.contains('connection') ||
        message.contains('closed') ||
        message.contains('isolate') ||
        message.contains('native');
  }

  Future<bool> _routeStillOwnsResult(
    LocalAiService local,
    String routedModelId,
  ) async =>
      await LocalBrainRoutePolicy.enabled() &&
      local.activeId == routedModelId &&
      local.scannerEnabled &&
      local.isModelScanReady(routedModelId);

  Future<MedicineScanDraft> _understandWithRecovery(
    LocalAiService local,
    String routedModelId,
    MedicineScanDraft draft,
    LocalScanRequest scanRequest,
  ) async {
    scanRequest.checkCurrent();
    try {
      return await local.understand(draft, scanRequest: scanRequest);
    } catch (error, stack) {
      scanRequest.checkCurrent();
      if (!_recoverableLocalTransportFailure(error)) {
        Error.throwWithStackTrace(error, stack);
      }

      // The failed inference lease has already been released by LocalAiService,
      // so foreground chat/model work may acquire the shared runtime before this
      // catch block runs. That is queue contention, not evidence that the saved
      // scan should permanently lose its AI refinement turn.
      if (local.busy || local.transferring) {
        throw StateError(_retryLocalAiWhenIdle);
      }

      // Chat already gets one clean-runtime retry. Scan refinement must have the
      // same transport semantics or one dropped native stream can silently turn
      // an active Aaris Brain capture into deterministic-only review. Retire only
      // the failed runtime, then require the exact route that produced this draft
      // to still be selected before retrying. A model/switch change can never
      // resurrect a stale result under a different Local AI identity.
      try {
        await local.suspend(scanRequest: scanRequest);
      } catch (suspendError) {
        scanRequest.checkCurrent();
        // Another caller can win the exclusive lease in the event-loop gap
        // between the availability snapshot above and suspend(). Preserve this
        // durable job in `reasoning` so it retries after that lease is released.
        if (local.busy ||
            local.transferring ||
            _localLeaseContention(suspendError)) {
          throw StateError(_retryLocalAiWhenIdle);
        }
        Error.throwWithStackTrace(error, stack);
      }
      if (!await _routeStillOwnsResult(local, routedModelId) ||
          local.activeId != routedModelId) {
        throw StateError(
          'Aaris Brain route changed while recovering this scan. Deterministic OCR draft retained for review.',
        );
      }
      scanRequest.checkCurrent();

      // Durable intake never uses the instant-review mayReasonWith timeout here.
      // If a caller races into the lease after this route check, understand()
      // throws the normal busy signal and _reason keeps the same AI index queued.
      return local.understand(draft, scanRequest: scanRequest);
    }
  }

  Future<void> _reason(MedicineIntakeJob job) async {
    if (job.status != 'reasoning') return;
    final scanRequest = _scanRequestFor(job);
    try {
      scanRequest.checkCurrent();
      final local = LocalAiService.instance;
      final readiness = await LocalBrainRoutePolicy.reasoningReadiness(
        local,
        job.modelId,
        scanRequest: scanRequest,
      );
      scanRequest.checkCurrent();
      if (readiness == LocalBrainRouteReadiness.retryWhenIdle) {
        job.error = _waitingForLocalAi;
        job.status = 'reasoning';
        return;
      }
      if (readiness != LocalBrainRouteReadiness.ready) {
        job.error = 'Aaris Brain is off, not scan-ready, or the selected Local AI changed. Deterministic OCR draft retained for review.';
        job.status = 'review';
        return;
      }
      if (job.aiIndex >= job.drafts.length) {
        job.status = 'review';
        return;
      }

      // Bind one AI refinement to the exact Local AI route that owns this turn.
      // The capture may legitimately wait through earlier model changes, but once
      // inference starts its result is valid only for that concrete route. This is
      // the same stale-callback principle used by the foreground import inbox.
      final routedModelId = local.activeId;
      if (routedModelId == null ||
          !local.scannerEnabled ||
          !local.isModelScanReady(routedModelId)) {
        job.error = 'The active Local AI route disappeared before scan reasoning started. Deterministic OCR draft retained for review.';
        job.status = 'review';
        return;
      }

      final index = job.aiIndex;
      final original = job.drafts[index];
      try {
        final candidate = await _understandWithRecovery(
          local,
          routedModelId,
          original,
          scanRequest,
        );
        scanRequest.checkCurrent();
        if (!await _routeStillOwnsResult(local, routedModelId)) {
          scanRequest.checkCurrent();
          job.error = 'Aaris Brain was turned off or its Local AI changed while this scan was being reviewed. The stale AI result was discarded; deterministic OCR was retained.';
          job.status = 'review';
          return;
        }
        scanRequest.checkCurrent();
        job.drafts[index] = candidate;
        if (job.error == _waitingForLocalAi) job.error = '';
      } catch (e) {
        scanRequest.checkCurrent();
        // Foreground chat and scan refinement share one authoritative local-model
        // lease. A narrow race can occur after the pump sees `busy == false` but
        // before `understand()` acquires it. Contention is not an extraction
        // failure: keep the same draft/index queued and resume when the lease is
        // released instead of silently skipping AI refinement forever.
        if (_localLeaseContention(e)) {
          if (job.error.isEmpty) job.error = _waitingForLocalAi;
          job.status = 'reasoning';
          return;
        }
        job.error =
            'Local AI could not validate all fields; original OCR draft retained. $e';
      }

      job.aiIndex++;
      if (job.aiIndex >= job.drafts.length) job.status = 'review';
    } catch (error) {
      // Timeout/Next already froze the draft. Never restore reasoning, advance
      // its index, or publish an AI result after that boundary.
      if (scanRequest.cancelled || job.status != 'reasoning') return;
      job.error =
          'Local AI review could not finish. Scanned details retained. $error';
      job.status = 'review';
    }
  }

  Future<void> retry(MedicineIntakeJob job, {bool rescanVideo = false}) async {
    // A durable terminal checkpoint can become visible before the worker has
    // finished source cleanup/final persistence. Wait only for this exact job;
    // unrelated captures continue to enqueue and process independently.
    await _workBarrier.wait(job.id);
    await _enqueue(() async {
      if (!_jobs.contains(job) || !job.terminal) return;
      if (rescanVideo && !job.canRescanVideo) {
        throw StateError(
          'The original video is no longer available for rescan.',
        );
      }
      if (job.kind == 'video' &&
          job.path.isNotEmpty &&
          (rescanVideo ||
              (job.drafts.isEmpty && job.cursorMs >= job.durationMs))) {
        // A failed empty video reached EOF. Retrying from that cursor would
        // read zero frames forever. Restart only the retained source; never mix
        // new sampling with drafts from its previous pass.
        job.cursorMs = 0;
        job.aiIndex = 0;
        job.unreadableFrames = 0;
        job.evidence = [];
        job.drafts = [];
        job.status = 'queued';
      } else if (job.kind == 'video' &&
          job.path.isNotEmpty &&
          job.cursorMs < job.durationMs) {
        job.status = 'queued';
      } else if (job.drafts.isNotEmpty) {
        job.modelId = await LocalBrainRoutePolicy.captureModelId(
          LocalAiService.instance,
        );
        job.aiIndex = 0;
        job.status = job.modelId == null ? 'review' : 'reasoning';
      } else {
        job.status = 'queued';
      }
      job.error = '';
      persistenceError = '';
      await _persist(job);
    });
    _kick();
  }

  Future<void> dismiss(MedicineIntakeJob job) async {
    await _workBarrier.wait(job.id);
    await _enqueue(() async {
      if (!_jobs.contains(job)) return;
      if (!job.terminal) {
        throw StateError(
          'Wait for processing to finish before removing this capture.',
        );
      }
      final deleted = await _database!.delete(
        'jobs',
        where: 'id=?',
        whereArgs: [job.id],
      );
      if (deleted != 1) {
        throw StateError('Capture draft could not be dismissed safely.');
      }
      _jobs.remove(job);

      // SQLite owns dismissal. Source-file cleanup is housekeeping and must not
      // turn a successfully removed durable job into a false dismissal failure.
      if (job.path.isNotEmpty && job.path == _capturePath(job.id, job.kind)) {
        try {
          final file = File(job.path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      notifyListeners();
    });
  }
}
