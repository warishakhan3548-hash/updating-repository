from pathlib import Path

Path("test/scan_auto_save_decision_test.dart").write_text("""import 'package:aaris_pharmacy/domain/intake_resolution.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_scan_commit.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedMedicineField _field(
  String value, {
  double confidence = .95,
}) => ExtractedMedicineField(
  value: value,
  confidence: confidence,
  support: 2,
  conflicted: false,
);

MedicineScanDraft _draft({
  double coreConfidence = .95,
  double overall = .95,
  String batch = 'B-100',
}) => MedicineScanDraft(
  fields: <String, ExtractedMedicineField>{
    'name': _field('Dolo 650'),
    'brand': _field('Dolo 650', confidence: coreConfidence),
    'salt': _field('Paracetamol', confidence: coreConfidence),
    'strength': _field('650 mg', confidence: coreConfidence),
    'form': _field('Tablet', confidence: coreConfidence),
    'batchNumber': _field(batch),
    'barcode': _field('8901234567890'),
    'expiry': _field('2027-12'),
    'mfg': _field('2026-01'),
  },
  rawText:
      'DOLO 650 TABLETS COMPOSITION Paracetamol IP 650 mg Batch $batch MFG 01/2026 EXP 12/2027',
  searchKeywords: 'dolo 650 paracetamol',
  frameSequences: const <int>[1],
  expiryMonthOnly: true,
  mfgMonthOnly: true,
  overallConfidence: overall,
);

Medicine _savedLot() => Medicine.fromJson(<String, dynamic>{
  'id': 'lot-a',
  'name': 'Dolo 650',
  'brand': 'Dolo 650',
  'salt': 'Paracetamol',
  'strength': '650 mg',
  'form': 'Tablet',
  'batchNumber': 'B-100',
  'barcode': '8901234567890',
  'expiry': '2027-12',
  'mfg': '2026-01',
  'quantity': 10,
});

void main() {
  final today = DateTime(2026, 9, 11);

  test('new stock needs scan-verified Local AI before auto-save', () {
    final draft = _draft();
    final resolution = resolveIntakeDraft(
      draft: draft,
      records: const <Medicine>[],
      today: today,
    );
    expect(
      scanAutoSaveDecision(draft, resolution, localAiVerified: false).allowed,
      isFalse,
    );
    expect(
      scanAutoSaveDecision(draft, resolution, localAiVerified: true).allowed,
      isTrue,
    );
  });

  test('machine commit uses a stronger 0.88 core confidence floor', () {
    final draft = _draft(coreConfidence: .87);
    final resolution = resolveIntakeDraft(
      draft: draft,
      records: const <Medicine>[],
      today: today,
    );
    final decision = scanAutoSaveDecision(
      draft,
      resolution,
      localAiVerified: true,
    );
    expect(decision.allowed, isFalse);
    expect(decision.reason, contains('source-verified'));
  });

  test('overall confidence below 0.88 remains human review', () {
    final draft = _draft(overall: .87);
    final resolution = resolveIntakeDraft(
      draft: draft,
      records: const <Medicine>[],
      today: today,
    );
    final decision = scanAutoSaveDecision(
      draft,
      resolution,
      localAiVerified: true,
    );
    expect(decision.allowed, isFalse);
    expect(decision.reason, contains('confidence floor'));
  });

  test('exact existing lot never silently becomes a duplicate row', () {
    final draft = _draft();
    final resolution = resolveIntakeDraft(
      draft: draft,
      records: <Medicine>[_savedLot()],
      today: today,
    );
    expect(resolution.kind, IntakeResolutionKind.exactLot);
    final decision = scanAutoSaveDecision(
      draft,
      resolution,
      localAiVerified: true,
    );
    expect(decision.allowed, isFalse);
    expect(decision.reason, contains('existing stock row'));
  });

  test('trusted different batch may auto-save as a distinct batch', () {
    final draft = _draft(batch: 'B-200');
    final resolution = resolveIntakeDraft(
      draft: draft,
      records: <Medicine>[_savedLot()],
      today: today,
    );
    expect(resolution.kind, IntakeResolutionKind.sameProduct);
    final decision = scanAutoSaveDecision(
      draft,
      resolution,
      localAiVerified: true,
    );
    expect(decision.allowed, isTrue);
    expect(decision.isNewBatch, isTrue);
  });
}
""")

Path("docs/AARIS_SCAN_LOCAL_AI_AUTOSAVE_2026_09_11.md").write_text("""# Aaris Scanner → Local AI → Safe Auto-Save

## Dependency tree

`ScannerScreen` still capture → `MedicineVisionService` OCR/barcode → deterministic medicine understanding → `ImportInboxScreen._prepare` → `LocalBrainRoutePolicy` privacy/readiness/lease authority → selected on-device `LocalAiService.understand` → `validateLocalScan` source validation → live `resolveIntakeDraft` collision check → `scanAutoSaveDecision` machine-commit gate → `medicineFromConfirmedScan` domain validation → `PharmacyController.save(expectedRevision)` serialized CAS persistence → controller notification/UI refresh.

## UI / state map

User opens **Scan medicine** → taps **Capture & automate** → still-frame OCR completes → scanner returns automatically (no **Use scan** tap) → Aaris Brain leases the active Local AI when enabled → validated AI evidence is merged → one safe new-stock/new-batch draft can auto-save (no **Confirm & add** tap) → inventory revision changes → UI refreshes from the authoritative database.

If Local AI is absent/off, the active model is not scan-verified, multiple medicines are detected, evidence conflicts, core confidence is below 0.88, an exact lot already exists, or inventory changes during reasoning, automatic save stops and the normal review UI remains authoritative.

## Surgical intersection

The LLM never receives database mutation authority. Automation is injected after validated Local-AI enrichment and immediately before the existing revision/CAS save boundary. OCR/LLM work stays probabilistic upstream; duplicate identity, lot integrity, chronology, confidence and persistence stay deterministic.

## Safety invariants

- Direct camera scanner only; photo/video/text/prepared batch imports keep explicit review.
- Exactly one medicine draft can auto-commit.
- Aaris Brain must be enabled and the exact active Local AI must both review the draft and have passed scan setup verification.
- Brand, Salt, Strength and Form must each be non-conflicting and at least 0.88 confidence.
- Existing `scanQuickAddDecision` must also pass.
- Exact saved lots and ambiguous matches never auto-create duplicate rows.
- Live inventory is re-resolved immediately before commit.
- `expectedRevision` CAS remains the final persistence authority.
- A scanner session makes only one automatic save attempt; any race or failure falls back to review rather than silently retrying a write.
""")
