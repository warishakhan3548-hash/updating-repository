import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/medicine.dart';
import '../domain/medicine_evidence_focus.dart';
import '../domain/medicine_resolution_v2.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';
import 'canonical_medicine_catalog_service.dart';

/// The single authoritative deterministic gateway for camera scans, uploaded
/// photos/videos, pasted text and imported text rows.
///
/// Inputs keep their complete OCR for audit/search. A layout-aware copy is fed
/// to candidate retrieval and Resolver V2 so browser chrome, timestamps and
/// unrelated screenshot text cannot become medicine identity merely because it
/// appeared early in OCR order.
class MedicineResolutionService {
  MedicineResolutionService._();

  static final MedicineResolutionService instance = MedicineResolutionService._();

  Future<MedicineUnderstandingResult> resolve({
    required Iterable<MedicineFrameEvidence> evidence,
    required Iterable<Medicine> records,
  }) async {
    final rawFrames = evidence
        .take(maxMedicineEvidenceFrames)
        .toList(growable: false);
    if (rawFrames.isEmpty) {
      return const MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[],
      );
    }

    final focusedFrames = focusMedicineEvidence(rawFrames);
    final knowledge = medicineKnowledgeFromRecords(records)
        .map((entry) => entry.toMessage())
        .toList(growable: false);

    // Master catalogue is an optional recognition accelerator. Failure or an
    // empty catalogue never disables the offline Tier-1 pharmacist memory.
    final catalogue = await CanonicalMedicineCatalogService.instance
        .candidatesForEvidence(focusedFrames);

    final result = MedicineUnderstandingResult.fromMessage(
      await compute(understandMedicineEvidenceV2Message, <String, Object?>{
        'evidence': focusedFrames
            .map((frame) => frame.toMessage())
            .toList(growable: false),
        'knowledge': knowledge,
        'catalog': catalogue
            .map((product) => product.toMessage())
            .toList(growable: false),
      }),
    );

    return MedicineUnderstandingResult(
      drafts: result.drafts
          .map((draft) => _attachCompleteRawOcr(draft, rawFrames))
          .toList(growable: false),
      ignoredFrames: result.ignoredFrames,
    );
  }
}

MedicineScanDraft _attachCompleteRawOcr(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> rawFrames,
) {
  final wanted = draft.frameSequences.toSet();
  final source = wanted.isEmpty
      ? rawFrames
      : rawFrames.where((frame) => wanted.contains(frame.sequence));
  final seen = <String>{};
  final buffer = StringBuffer();
  var remaining = maxPersistedRawOcrCharacters;

  for (final frame in source) {
    final raw = frame.text.trim();
    if (raw.isEmpty) continue;
    final key = searchText(raw);
    if (key.isEmpty || !seen.add(key)) continue;
    final separator = buffer.isEmpty ? '' : '\n';
    if (remaining <= separator.length) break;
    buffer.write(separator);
    remaining -= separator.length;
    final take = min(remaining, raw.length);
    buffer.write(raw.substring(0, take));
    remaining -= take;
    if (take < raw.length || remaining == 0) break;
  }

  final rawOcr = buffer.toString();
  final combined = composeRawAndFocusedOcr(
    rawOcr: rawOcr.isEmpty ? draft.rawText : rawOcr,
    focusedEvidence: draft.rawText,
  );
  return MedicineScanDraft(
    fields: draft.fields,
    rawText: combined,
    searchKeywords: draft.searchKeywords,
    frameSequences: draft.frameSequences,
    expiryMonthOnly: draft.expiryMonthOnly,
    mfgMonthOnly: draft.mfgMonthOnly,
    printedPackSize: draft.printedPackSize,
    printedMrp: draft.printedMrp,
    overallConfidence: draft.overallConfidence,
  );
}
