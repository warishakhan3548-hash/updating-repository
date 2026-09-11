import 'dart:async';

import 'medicine.dart';
import 'medicine_understanding.dart';

/// A durable capture job is not inventory. No state transition here grants a
/// model permission to save a Medicine; the existing editor/action review does.
class MedicineIntakeJob {
  MedicineIntakeJob({
    required this.id,
    required this.kind,
    required this.title,
    this.path = '',
    this.status = 'queued',
    this.error = '',
    this.modelId,
    this.cursorMs = 0,
    this.durationMs = 0,
    this.aiIndex = 0,
    List<MedicineFrameEvidence>? evidence,
    List<MedicineScanDraft>? drafts,
  }) : evidence = evidence ?? [],
       drafts = drafts ?? [];
  final String id, kind, title;
  String path, status, error;
  String? modelId;
  int cursorMs, durationMs, aiIndex;
  List<MedicineFrameEvidence> evidence;
  List<MedicineScanDraft> drafts;
  bool get ready => status == 'review';
  bool get terminal => ready || status == 'failed';
  double? get videoProgress => durationMs > 0 ? cursorMs / durationMs : null;
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'path': path,
    'status': status,
    'error': error,
    'modelId': modelId,
    'cursorMs': cursorMs,
    'durationMs': durationMs,
    'aiIndex': aiIndex,
    'evidence': evidence.map((e) => e.toMessage()).toList(),
    'drafts': drafts.map((d) => d.toMessage()).toList(),
  };
  factory MedicineIntakeJob.fromJson(Map<String, dynamic> json) {
    final id = json['id'], kind = json['kind'], status = json['status'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !{'photo', 'video', 'evidence'}.contains(kind) ||
        !{
          'queued',
          'processing',
          'reasoning',
          'review',
          'failed',
        }.contains(status)) {
      throw const FormatException('Invalid saved capture job.');
    }
    for (final key in ['title', 'path', 'error']) {
      final value = json[key];
      if (value is! String || value.length > 10000) {
        throw const FormatException('Invalid saved capture text.');
      }
    }
    final model = json['modelId'];
    if (model != null &&
        (model is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(model))) {
      throw const FormatException('Invalid saved capture model.');
    }
    for (final key in ['cursorMs', 'durationMs', 'aiIndex']) {
      final value = json[key];
      if (value is! int || value < 0 || value > 3600000) {
        throw const FormatException('Invalid saved capture cursor.');
      }
    }
    final rawEvidence = json['evidence'], rawDrafts = json['drafts'];
    if (rawEvidence is! List ||
        rawDrafts is! List ||
        rawEvidence.length > maxMedicineEvidenceFrames ||
        rawDrafts.length > 500 ||
        rawEvidence.any((e) => e is! Map) ||
        rawDrafts.any((d) => d is! Map) ||
        (json['aiIndex'] as int) > rawDrafts.length ||
        ((json['durationMs'] as int) > 0 &&
            (json['cursorMs'] as int) > (json['durationMs'] as int))) {
      throw const FormatException(
        'Invalid saved capture evidence or checkpoint.',
      );
    }
    final evidence = (json['evidence'] as List)
        .whereType<Map>()
        .map(
          (e) =>
              MedicineFrameEvidence.fromMessage(Map<Object?, Object?>.from(e)),
        )
        .toList();
    final drafts = (json['drafts'] as List)
        .whereType<Map>()
        .map(
          (d) => MedicineScanDraft.fromMessage(Map<Object?, Object?>.from(d)),
        )
        .toList();
    if (evidence.length > maxMedicineEvidenceFrames || drafts.length > 500) {
      throw const FormatException(
        'Saved capture job exceeds the supported size.',
      );
    }
    return MedicineIntakeJob(
      id: id,
      kind: kind as String,
      title: json['title'] as String,
      path: json['path'] as String,
      status: status as String,
      error: json['error'] as String,
      modelId: json['modelId'] as String?,
      cursorMs: json['cursorMs'] as int,
      durationMs: json['durationMs'] as int,
      aiIndex: json['aiIndex'] as int,
      evidence: evidence,
      drafts: drafts,
    );
  }
}

/// Coordinates one worker-owned capture with user terminal actions.
///
/// OCR/video processing deliberately checkpoints durable review state before
/// private source cleanup finishes. The UI can therefore observe `review` or
/// `failed` for a few asynchronous instructions while the worker still owns the
/// same row. Retry/Dismiss must wait for that exact ownership lease to end; a
/// global queue lock would unnecessarily block unrelated captures.
class MedicineIntakeWorkBarrier {
  String? _activeId;
  Completer<void>? _released;

  bool owns(String id) => _activeId == id;

  void begin(String id) {
    if (_released != null) {
      throw StateError('A medicine intake worker lease is already active.');
    }
    _activeId = id;
    _released = Completer<void>();
  }

  Future<void> wait(String id) {
    final released = _activeId == id ? _released : null;
    return released?.future ?? Future<void>.value();
  }

  void finish(String id) {
    // A stale finalizer can never release a newer capture's lease.
    if (_activeId != id) return;
    final released = _released;
    _activeId = null;
    _released = null;
    if (released != null && !released.isCompleted) released.complete();
  }
}

/// Alternate durable OCR/capture work with Local AI reasoning when both are
/// available. A stream of freshly queued photos must not starve already-read OCR
/// from its capture-bound Local AI handoff; chat still wins because callers set
/// [allowReasoning] false while the shared model lease is occupied.
///
/// Camera evidence is an interactive lane: its OCR already exists when it enters
/// this scheduler, so making it wait behind file-backed photo/video decoding adds
/// latency without improving durability. Give the oldest direct-camera job first
/// chance to become a deterministic draft and, once that draft is ready, first
/// chance to reach its capture-bound Local AI. This keeps Scan -> Preview feeling
/// immediate while preserving FIFO inside the interactive lane and the existing
/// alternating fairness for queued media imports.
MedicineIntakeJob? nextMedicineIntakeJob(
  Iterable<MedicineIntakeJob> jobs, {
  required bool allowReasoning,
  required bool preferReasoning,
}) {
  final interactiveReasoning = allowReasoning
      ? jobs
            .where((j) => j.kind == 'evidence' && j.status == 'reasoning')
            .firstOrNull
      : null;
  if (interactiveReasoning != null) return interactiveReasoning;

  final interactiveCapture = jobs
      .where((j) => j.kind == 'evidence' && j.status == 'queued')
      .firstOrNull;
  if (interactiveCapture != null) return interactiveCapture;

  final reasoning = allowReasoning
      ? jobs.where((j) => j.status == 'reasoning').firstOrNull
      : null;
  if (preferReasoning && reasoning != null) return reasoning;

  // Fresh file-backed photos get OCR ahead of video windows so their durable
  // text exists as soon as possible. After one capture step the pump flips
  // preferReasoning, giving an awaiting Local AI draft its fair turn before the
  // next photo.
  final photo = jobs
      .where((j) => j.status == 'queued' && j.kind != 'video')
      .firstOrNull;
  if (photo != null) return photo;

  final video = jobs.where((j) => j.status == 'queued').firstOrNull;
  return preferReasoning ? reasoning ?? video : video ?? reasoning;
}

/// Carry the final unresolved object across video windows. Completed objects
/// are emitted once; windows are checkpointed with the carry and cursor together.
class MedicineVideoWindowResult {
  const MedicineVideoWindowResult(this.completed, this.carry);
  final List<MedicineScanDraft> completed;
  final List<MedicineFrameEvidence> carry;
}

MedicineVideoWindowResult finishMedicineVideoWindow(
  List<MedicineFrameEvidence> frames,
  List<MedicineScanDraft> drafts, {
  required bool isLast,
}) {
  if (isLast) return MedicineVideoWindowResult(drafts, const []);
  if (drafts.isEmpty) {
    return MedicineVideoWindowResult(
      const [],
      frames.length > 24 ? frames.sublist(frames.length - 24) : frames,
    );
  }
  final tail = drafts.last.frameSequences.toSet();
  final carry = frames.where((frame) => tail.contains(frame.sequence)).toList();
  // Keep distinct useful views, bounded below the domain frame cap. Carrying
  // only the latest frame would lose front-label identity when the camera flips.
  final bounded = carry.length <= 48
      ? carry
      : [...carry.take(24), ...carry.skip(carry.length - 24)];
  return MedicineVideoWindowResult(
    drafts.take(drafts.length - 1).toList(),
    bounded,
  );
}

String intakeId() => newId();
