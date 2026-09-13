import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_ocr_reliability.dart';

void main() {
  test('missing OCR confidence preserves historical capture score', () {
    expect(
      confidenceAwareMedicineEvidenceQuality(
        captureQuality: .63,
        ocrConfidence: null,
      ),
      .63,
    );
  });

  test('detector confidence changes evidence weight conservatively', () {
    final low = confidenceAwareMedicineEvidenceQuality(
      captureQuality: .8,
      ocrConfidence: .25,
    );
    final high = confidenceAwareMedicineEvidenceQuality(
      captureQuality: .8,
      ocrConfidence: .95,
    );
    expect(low, lessThan(.8));
    expect(high, greaterThan(low));
    expect(high, lessThanOrEqualTo(.85));
  });

  test('frame OCR confidence is bounded and duplicate-safe', () {
    final score = robustMedicineOcrConfidence(const [
      MedicineOcrConfidenceSample(text: 'Paracetamol 650 mg', confidence: .91),
      MedicineOcrConfidenceSample(text: ' paracetamol  650 mg ', confidence: .74),
      MedicineOcrConfidenceSample(text: 'EXP 10/2027', confidence: .62),
      MedicineOcrConfidenceSample(text: 'BATCH A12', confidence: .84),
    ]);
    expect(score, isNotNull);
    expect(score!, inInclusiveRange(0, 1));
    expect(score, greaterThan(.65));
    expect(score, lessThan(.92));
  });

  test('unknown detector confidence stays unknown instead of becoming zero', () {
    expect(
      robustMedicineOcrConfidence(const [
        MedicineOcrConfidenceSample(text: 'DOLO 650', confidence: null),
      ]),
      isNull,
    );
  });
}
