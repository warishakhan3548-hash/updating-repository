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
