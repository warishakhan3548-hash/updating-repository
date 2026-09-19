import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V35', () {
    test('explicit trade name keeps variant number but drops dose unit and form', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: 'BRAND NAME: CROCIN 650 mg TABLETS',
          quality: .98,
        ),
      ]);

      expect(result.brand.toLowerCase(), 'crocin 650');
      expect(result.conflicted, isFalse);
    });

    test('semantic labels skip one presentation-only OCR row', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: '''BRAND NAME
TABLETS
DOLO 650
GENERIC NAME
TABLET
Paracetamol 650 mg''',
          quality: .98,
        ),
      ]);

      expect(result.brand.toLowerCase(), 'dolo 650');
      expect(result.genericName.toLowerCase(), 'paracetamol');
      expect(result.salt.toLowerCase(), 'paracetamol');
      expect(result.strength, '650 mg');
      expect(result.conflicted, isFalse);
    });

    test('composition disagreement does not erase clean independent brand', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 1,
          text: '''BRAND NAME: CALPOL
GENERIC NAME: Paracetamol 500 mg
WARNING KEEP OUT OF REACH
STORAGE BELOW 25 C
PRESCRIPTION SCHEDULE H''',
          quality: .98,
        ),
        MedicineFrameEvidence(
          sequence: 2,
          text: '''BRAND NAME: CALPOL
GENERIC NAME: Paracetamol 650 mg
MANUFACTURED BY ACME PHARMA LTD
MARKETED AND DISTRIBUTED IN INDIA
CUSTOMER CARE ADDRESS''',
          quality: .98,
        ),
      ]);

      expect(result.brand.toLowerCase(), 'calpol');
      expect(result.components, isEmpty);
      expect(result.salt, isEmpty);
      expect(result.strength, isEmpty);
      expect(result.conflicted, isFalse);
    });
  });
}
