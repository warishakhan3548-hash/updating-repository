import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine semantic adjacency V21', () {
    test('standalone brand and generic labels own adjacent values and dose', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: '''BRAND NAME
DOLO 650
GENERIC NAME
Paracetamol
650 mg
Tablets''',
          quality: .96,
        ),
      ]);

      expect(result.brand.toLowerCase(), 'dolo 650');
      expect(result.genericName.toLowerCase(), 'paracetamol');
      expect(result.salt.toLowerCase(), 'paracetamol');
      expect(result.strength, '650 mg');
      expect(result.conflicted, isFalse);
    });

    test('inline generic dose is excluded from the generic identity', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: 'Generic Name: Paracetamol 500 mg\nTablets',
          quality: .95,
        ),
      ]);

      expect(result.genericName.toLowerCase(), 'paracetamol');
      expect(result.salt.toLowerCase(), 'paracetamol');
      expect(result.strength, '500 mg');
      expect(result.conflicted, isFalse);
    });

    test('pharmacopoeial ingredient and dose may be split across OCR rows', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: 'PARACETAMOL I.P.\n650 mg\nTablets',
          quality: .95,
        ),
      ]);

      expect(result.salt.toLowerCase(), 'paracetamol');
      expect(result.strength, '650 mg');
      expect(result.genericName.toLowerCase(), 'paracetamol');
      expect(result.brand, isEmpty);
      expect(result.conflicted, isFalse);
    });

    test('brand plus adjacent dose is not hallucinated as composition', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: 'CROCIN\n650 mg\nTablets',
          quality: .95,
        ),
      ]);

      expect(result.brand.toLowerCase(), 'crocin');
      expect(result.salt, isEmpty);
      expect(result.strength, isEmpty);
      expect(result.components, isEmpty);
      expect(result.conflicted, isFalse);
    });
  });
}
