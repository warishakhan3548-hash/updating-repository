import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_evidence_normalization.dart';
import '../lib/domain/medicine_understanding.dart';

void main() {
  test('layout-only frame remains readable before video/live empty-text gates', () {
    const input = MedicineFrameEvidence(
      sequence: 20000, timestampMs: 20000, quality: .7,
      source: 'photo', startsNewItem: true,
      layoutLines: [
        MedicineTextLineEvidence(text: '500 mg',
          left: 80, top: 21, width: 70, height: 12),
        MedicineTextLineEvidence(text: 'AZITHRAL',
          left: 0, top: 0, width: 100, height: 18),
        MedicineTextLineEvidence(text: 'Azithromycin',
          left: 0, top: 20, width: 70, height: 12),
      ],
    );
    final output = normalizeMedicineFrameEvidence(input);
    expect(output.text, 'AZITHRAL\nAzithromycin\n500 mg');
    expect(output.sequence, 20000);
    expect(output.timestampMs, 20000);
    expect(output.startsNewItem, isTrue);
    expect(output.layoutLines, same(input.layoutLines));
    expect(output.quality, .7);
  });
  test('existing raw OCR is never replaced by reconstructed text', () {
    const input = MedicineFrameEvidence(text: 'raw OCR', layoutLines: [
      MedicineTextLineEvidence(text: 'other observed line',
        left: 0, top: 0, width: 20, height: 10),
    ]);
    expect(normalizeMedicineFrameEvidence(input), same(input));
  });
  test('evidence reconstruction is idempotent and bounds frame count', () {
    const input = MedicineFrameEvidence(layoutLines: [
      MedicineTextLineEvidence(text: 'EXP 05/28',
        left: 0, top: 0, width: 20, height: 10),
    ]);
    final first = normalizeMedicineFrameEvidence(input);
    expect(normalizeMedicineFrameEvidence(first), same(first));
    expect(() => normalizeMedicineReviewEvidence(List.filled(1000, input)),
      throwsFormatException);
  });
}
