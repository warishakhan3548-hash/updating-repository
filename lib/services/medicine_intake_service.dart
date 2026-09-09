import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/medicine.dart';
import '../domain/medicine_intake.dart';
import '../domain/medicine_understanding.dart';
import 'local_ai_service.dart';
import 'media_import_service.dart';
import 'scan_service.dart';

/// Persistent, bounded work queue shared by AI Hub and ordinary import.
/// Captures are acknowledged after private-file copy + SQLite job commit,
/// independently of OCR/LLM latency. Inventory is never written by this service.
class MedicineIntakeService extends ChangeNotifier with WidgetsBindingObserver {
  MedicineIntakeService._() {
    LocalAiService.instance.addListener(_modelChanged);
  }
  static final instance = MedicineIntakeService._();
  static const capacity = 250;
  final _jobs = <MedicineIntakeJob>[];
  final _media = MediaImportService();
  Database? _database;
  Directory? _root;
  Future<void>? _initializing;
  Future<void> _intakeWrites = Future.value();
  bool _running = false, _paused = false;
  bool _ready = false, _preferReasoning = false, _observingMemory = false;
  String persistenceError = '';
  Iterable<Medicine> Function()? _records;
  int Function()? _revision;
  int? _knowledgeRevision;
  List<Map<String, Object?>>? _knowledge;
  String pauseReason = '';

  List<MedicineIntakeJob> get jobs => List.unmodifiable(_jobs);
  bool get full => _jobs.length >= capacity;
  bool get processing => _running;
  bool get paused => _paused;
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
    _root = await Directory(
      '${support.path}/medicine_intake',
    ).create(recursive: true);
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
    if (rows.length > capacity)
      throw StateError('Intake queue exceeds capacity.');
    final restored = <MedicineIntakeJob>[];
    for (final row in rows) {
      final raw = row['data'] as String;
      if (raw.length > 20000000) throw StateError('Saved intake is too large.');
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
    await LocalAiService.instance.initialize();
    _jobs
      ..clear()
      ..addAll(restored);
    if (!_observingMemory) {
      WidgetsBinding.instance.addObserver(this);
      _observingMemory = true;
    }
    _ready = true;
    notifyListeners();
  }

  String _capturePath(String id, String kind) =>
      '${_root!.path}/$id.${kind == 'video' ? 'mp4' : 'jpg'}';

  Future<void> _persist(MedicineIntakeJob job, {bool insert = false}) async {
    final data = jsonEncode(job.toJson());
    if (data.length > 20000000)
      throw StateError('Capture draft limit reached. Split this video.');
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
      if (changed != 1)
        throw StateError('Capture checkpoint could not be saved.');
    }
    notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final future = _intakeWrites.then((_) => action());
    _intakeWrites = future.catchError((Object _) {});
    return future;
  }

  Future<void> addFile(
    String path, {
    required String kind,
    required String title,
  }) => _enqueue(() async {
    await initialize();
    if (!supported)
      throw UnsupportedError('Capture queue requires the Android app.');
    if (full)
      throw StateError(
        'Review/dismiss some captures before adding more (limit $capacity).',
      );
    if (kind != 'photo' && kind != 'video')
      throw const FormatException('Invalid capture type.');
    final local = LocalAiService.instance;
    final job = MedicineIntakeJob(
      id: intakeId(),
      kind: kind,
      title: title,
      modelId: local.hasSelection && local.scannerEnabled
          ? local.activeId
          : null,
    );
    job.path = _capturePath(job.id, kind);
    try {
      final length = await File(path).length();
      final facts = await const MethodChannel(
        'com.aaris.pharmacy/documents',
      ).invokeMapMethod<String, dynamic>('localAiDeviceInfo');
      final free = facts?['freeStorage'];
      if (length <= 0 || (free is int && free < length + 128 * 1024 * 1024)) {
        throw StateError(
          'Not enough private storage to safely queue this capture. Original file is unchanged.',
        );
      }
      await File(path).copy(job.path);
      if (await File(job.path).length() != length) {
        throw StateError(
          'Incomplete capture copy. Please select the original again.',
        );
      }
      await _persist(job, insert: true);
      _jobs.add(job);
    } catch (_) {
      final copy = File(job.path);
      if (await copy.exists()) await copy.delete();
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
    if (!supported)
      throw UnsupportedError('Capture queue requires the Android app.');
    if (full ||
        evidence.isEmpty ||
        evidence.length > maxMedicineEvidenceFrames) {
      throw StateError('Empty capture or intake capacity exceeded.');
    }
    final local = LocalAiService.instance;
    final job = MedicineIntakeJob(
      id: intakeId(),
      kind: 'evidence',
      title: title,
      evidence: List.of(evidence),
      modelId: local.hasSelection && local.scannerEnabled
          ? local.activeId
          : null,
    );
    await _persist(job, insert: true);
    _jobs.add(job);
    notifyListeners();
    _kick();
  });

  @override
  void didHaveMemoryPressure() {
    _paused = true;
    pauseReason =
        'Device memory is low. Close other apps, then resume this saved queue.';
    _knowledge = null;
    _knowledgeRevision = null;
    notifyListeners();
  }

  void setPaused(bool value) {
    _paused = value;
    if (!value) pauseReason = '';
    notifyListeners();
    if (!value) _kick();
  }

  void _modelChanged() {
    if (!LocalAiService.instance.busy) _kick();
  }

  void _kick() {
    if (_running ||
        _paused ||
        !_ready ||
        _database == null ||
        _records == null ||
        persistenceError.isNotEmpty)
      return;
    unawaited(
      _pump().catchError((Object e) {
        persistenceError = 'Capture queue paused: $e';
        notifyListeners();
      }),
    );
  }

  Future<MedicineUnderstandingResult> _understand(
    List<MedicineFrameEvidence> frames,
  ) async {
    final revision = _revision?.call();
    if (_knowledge == null ||
        revision == null ||
        revision != _knowledgeRevision) {
      _knowledge = medicineKnowledgeFromRecords(
        _records!(),
      ).map((k) => k.toMessage()).toList();
      _knowledgeRevision = revision;
    }
    return MedicineUnderstandingResult.fromMessage(
      await compute(understandMedicineEvidenceMessage, <String, Object?>{
        'evidence': frames.map((e) => e.toMessage()).toList(),
        'knowledge': _knowledge!,
      }),
    );
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    try {
      while (!_paused) {
        // OCR/capture work has priority, so fast photos are turned into durable
        // text before slower semantic reasoning monopolizes the native model.
        final local = LocalAiService.instance;
        final job = nextMedicineIntakeJob(
          _jobs,
          allowReasoning: !local.busy && !local.transferring,
          preferReasoning: _preferReasoning,
        );
        if (job == null) break;
        try {
          if (job.status == 'reasoning') {
            _preferReasoning = false;
            await _reason(job);
          } else {
            _preferReasoning = true;
            job.status = 'processing';
            await _persist(job);
            if (job.kind == 'video')
              await _videoStep(job);
            else
              await _photoStep(job);
          }
          await _persist(job);
        } catch (e) {
          job.status = 'failed';
          job.error = e.toString();
          await _persist(job);
        }
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  void _ocrFinished(MedicineIntakeJob job) {
    job.status = job.modelId == null ? 'review' : 'reasoning';
    if (job.drafts.isEmpty) {
      job.status = 'failed';
      job.error = 'No medicine could be read. Take a closer, steadier photo.';
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
    if (job.status != 'failed' && job.path.isNotEmpty) {
      await File(job.path).delete();
      job.path = '';
    }
  }

  Future<void> _videoStep(MedicineIntakeJob job) async {
    final window = await _media.sampleVideoWindow(job.path, job.cursorMs);
    if (window.nextStartMs <= job.cursorMs && !window.complete) {
      throw StateError('Video sampler did not advance.');
    }
    final vision = MedicineVisionService();
    final evidence = List<MedicineFrameEvidence>.of(job.evidence);
    var unreadable = 0;
    try {
      for (final frame in window.frames) {
        try {
          evidence.add(
            await vision.analyzeFile(
              frame.path,
              source: job.title,
              sequence: frame.sequence,
              timestampMs: frame.timestampMs,
              quality: frame.quality,
            ),
          );
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
    if (unreadable > 0)
      job.error =
          'Some sampled frames were unreadable. Review completeness; video sampling cannot guarantee every pack.';
    if (window.complete)
      _ocrFinished(job);
    else
      job.status = 'queued';
    // Cursor + completed drafts + unresolved carry commit together.
    await _persist(job);
    if (window.complete && job.status != 'failed') {
      await File(job.path).delete();
      job.path = '';
    }
  }

  Future<void> _reason(MedicineIntakeJob job) async {
    final local = LocalAiService.instance;
    if (local.activeId != job.modelId || !local.scannerEnabled) {
      job.error =
          'Local model selection changed. Deterministic drafts retained for review.';
      job.status = 'review';
      return;
    }
    if (job.aiIndex >= job.drafts.length) {
      job.status = 'review';
      return;
    }
    try {
      job.drafts[job.aiIndex] = await local.understand(job.drafts[job.aiIndex]);
    } catch (e) {
      job.error =
          'Local AI could not validate all fields; original OCR draft retained. $e';
    }
    job.aiIndex++;
    if (job.aiIndex >= job.drafts.length) job.status = 'review';
  }

  Future<void> retry(MedicineIntakeJob job) async {
    if (!job.terminal) return;
    if (job.kind == 'video' &&
        job.path.isNotEmpty &&
        job.cursorMs < job.durationMs) {
      job.status = 'queued';
    } else if (job.drafts.isNotEmpty) {
      job.modelId = LocalAiService.instance.activeId;
      job.aiIndex = 0;
      job.status = job.modelId == null ? 'review' : 'reasoning';
    } else
      job.status = 'queued';
    job.error = '';
    persistenceError = '';
    await _persist(job);
    _kick();
  }

  Future<void> dismiss(MedicineIntakeJob job) async {
    if (!job.terminal)
      throw StateError('Pause/finish processing before dismissing a capture.');
    await _database!.delete('jobs', where: 'id=?', whereArgs: [job.id]);
    _jobs.remove(job);
    if (job.path.isNotEmpty && job.path == _capturePath(job.id, job.kind)) {
      final file = File(job.path);
      if (await file.exists()) await file.delete();
    }
    notifyListeners();
  }
}
