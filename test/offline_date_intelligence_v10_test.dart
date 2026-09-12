import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('V10 medicine date intelligence', () {
    test('parses space-separated full dates', () {
      expect(parseMedicineDateText('04 05 2028')?.value, '2028-05-04');
      expect(parseMedicineDateText('04/05/28')?.value, '2028-05-04');
      expect(parseMedicineDateText('2028 05 04')?.value, '2028-05-04');
    });

    test('repairs bounded OCR digit confusions inside a date', () {
      expect(parseMedicineDateText('O4 O5 2O28')?.value, '2028-05-04');
    });

    test('future unlabeled singleton is only an expiry review hint', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '04 05 2028'),
        ],
        referenceDate: DateTime.utc(2026, 9, 12),
      );
      expect(result.manufacturing, isNull);
      expect(result.expiry?.date.value, '2028-05-04');
      expect(result.expiry!.confidence, lessThan(.78));
      expect(result.expired, isFalse);
    });

    test('single past unlabeled date remains unclassified', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '04 05 2025'),
        ],
        referenceDate: DateTime.utc(2026, 9, 12),
      );
      expect(result.manufacturing, isNull);
      expect(result.expiry, isNull);
    });

    test('chronological pair infers MFG and future EXP', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '04 06 2026\n04 05 2028'),
        ],
        referenceDate: DateTime.utc(2026, 9, 12),
      );
      expect(result.manufacturing?.date.value, '2026-06-04');
      expect(result.expiry?.date.value, '2028-05-04');
      expect(result.conflicted, isFalse);
    });

    test('two past dates can still mean MFG plus expired EXP', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '04 06 2023\n04 06 2025'),
        ],
        referenceDate: DateTime.utc(2026, 9, 12),
      );
      expect(result.manufacturing?.date.value, '2023-06-04');
      expect(result.expiry?.date.value, '2025-06-04');
      expect(result.expired, isTrue);
    });

    test('explicit labels outrank temporal heuristics', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'MFG 04 06 2023\nEXP 04 06 2025'),
        ],
        referenceDate: DateTime.utc(2026, 9, 12),
      );
      expect(result.manufacturing?.date.value, '2023-06-04');
      expect(result.expiry?.date.value, '2025-06-04');
      expect(result.expiry!.explicitLabel, isTrue);
      expect(result.expired, isTrue);
    });

    test('month names and month-year remain supported', () {
      expect(parseMedicineDateText('EXP MAY 2028')?.value, '2028-05');
      expect(parseMedicineDateText('MFG 06/26')?.value, '2026-06');
    });

    test('duplicate video frames do not manufacture date support', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'EXP 05 2028', sequence: 1),
          MedicineFrameEvidence(text: 'EXP 05 2028', sequence: 2),
          MedicineFrameEvidence(text: 'EXP 05 2028', sequence: 3),
        ],
        referenceDate: DateTime.utc(2026, 9, 12),
      );
      expect(result.expiry?.support, 1);
    });

    test('impossible dates are rejected', () {
      expect(parseMedicineDateText('32 19 2028'), isNull);
      expect(parseMedicineDateText('31 02 2028'), isNull);
    });
  });
}
