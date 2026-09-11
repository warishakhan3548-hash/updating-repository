import 'package:aaris_pharmacy/domain/intake_resolution.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_scan_commit.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedMedicineField _field(String value, {double confidence = .95}) =>
    ExtractedMedicineField(
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

  test('new stock needs source-verified AI before auto-save', () {
    final draft = _draft();
    final resolution = resolveIntakeDraft(
      draft: draft,
      records: const <Medicine>[],
      today: today,
    );
    expect(
      scanAutoSaveDecision(draft, resolution, verifier: null).allowed,
      isFalse,
    );
    expect(
      scanAutoSaveDecision(
        draft,
        resolution,
        verifier: ScanAutoSaveVerifier.localAi,
      ).allowed,
      isTrue,
    );
    expect(
      scanAutoSaveDecision(
        draft,
        resolution,
        verifier: ScanAutoSaveVerifier.cloudAi,
      ).allowed,
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
      verifier: ScanAutoSaveVerifier.localAi,
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
      verifier: ScanAutoSaveVerifier.localAi,
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
      verifier: ScanAutoSaveVerifier.localAi,
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
      verifier: ScanAutoSaveVerifier.localAi,
    );
    expect(decision.allowed, isTrue);
    expect(decision.isNewBatch, isTrue);
  });
}
