import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine identity hardening V25', () {
    test('unlabelled legal company row cannot become the medicine brand', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: '''MICRO LABS LIMITED
CROCIN
Paracetamol I.P. 650 mg
10 TABLETS''',
          quality: .98,
        ),
      ]);

      expect(result.brand.toLowerCase(), 'crocin');
      expect(result.salt.toLowerCase(), 'paracetamol');
      expect(result.strength, '650 mg');
      expect(result.conflicted, isFalse);
    });

    test('generic-only pack with company heading does not invent a trade brand', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: '''ZENITH HEALTHCARE PVT LTD
PARACETAMOL TABLETS
Generic Name: Paracetamol
Composition
Each tablet contains
Paracetamol I.P. 500 mg''',
          quality: .97,
        ),
      ]);

      expect(result.brand, isEmpty);
      expect(result.genericName.toLowerCase(), 'paracetamol');
      expect(result.salt.toLowerCase(), 'paracetamol');
      expect(result.strength, '500 mg');
      expect(result.genericOnly, isTrue);
      expect(result.conflicted, isFalse);
    });

    test('missing date labels are recovered by chronology without company noise', () {
      final dates = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: '''MICRO LABS LIMITED
CROCIN
Paracetamol I.P. 650 mg
04/2026
04/2028''',
            quality: .98,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );

      expect(dates.manufacturing?.date.value, '2026-04');
      expect(dates.expiry?.date.value, '2028-04');
      expect(dates.conflicted, isFalse);
    });

    test('zero-width OCR controls do not split medicine tokens', () {
      expect(
        mergeMedicineOcrLines(<String>[
          'PARA\u200BCETAMOL 500 mg',
          'PARACETAMOL 500 mg',
        ]),
        <String>['PARACETAMOL 500 mg'],
      );
      expect(medicineOcrLineKey('CRO\u2060CIN'), 'crocin');
    });

    test('OCR line quality remains a bounded reliability signal', () {
      expect(medicineOcrLineQuality('||||||||||||'), 0);
      expect(medicineOcrLineQuality('PARACETAMOL 500 mg'), inInclusiveRange(0, 1));
    });
  });
}
