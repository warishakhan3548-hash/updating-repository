import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('V11 semantic medicine brain', () {
    test('separates trade name from two-ingredient FDC composition', () {
      final result = inferMedicineSemanticRoles(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: '''GLYCOMET GP 2
Tablets
Composition
Each tablet contains
Glimepiride IP 2 mg
Metformin Hydrochloride IP 500 mg
EXP 05 2028''',
            quality: .95,
          ),
        ],
      );

      expect(result.brand.toLowerCase(), contains('glycomet'));
      expect(result.salt.toLowerCase(), contains('glimepiride'));
      expect(result.salt.toLowerCase(), contains('metformin hydrochloride'));
      expect(result.strength, '2 mg + 500 mg');
      expect(result.components, hasLength(2));
      expect(result.conflicted, isFalse);
    });

    test('generic-only pack does not invent a trade brand', () {
      final result = inferMedicineSemanticRoles(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: '''PARACETAMOL TABLETS
Generic Name: Paracetamol
Composition
Each tablet contains
Paracetamol IP 500 mg''',
            quality: .96,
          ),
        ],
      );

      expect(result.salt.toLowerCase(), 'paracetamol');
      expect(result.genericName.toLowerCase(), 'paracetamol');
      expect(result.brand, isEmpty);
      expect(result.genericOnly, isTrue);
    });

    test('equivalent-to grammar keeps the clinically named ingredient', () {
      final result = inferMedicineSemanticRoles(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: '''Composition
Each tablet contains
Metformin Hydrochloride IP equivalent to Metformin 500 mg''',
          ),
        ],
      );

      expect(result.components, hasLength(1));
      expect(result.components.single.ingredient.toLowerCase(), 'metformin');
      expect(result.components.single.strength, '500 mg');
    });

    test('correlated duplicate camera frames count as one semantic vote', () {
      const frame = MedicineFrameEvidence(
        text: '''DOLO 650
Composition
Each tablet contains
Paracetamol IP 650 mg''',
        quality: .92,
      );
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        frame,
        MedicineFrameEvidence(
          text: '''DOLO 650
Composition
Each tablet contains
Paracetamol IP 650 mg''',
          quality: .91,
          sequence: 1,
        ),
      ]);

      expect(result.components, hasLength(1));
      expect(result.components.single.support, 1);
    });

    test('pharmacist aliases participate in first-stage local recognition', () {
      final result = const MedicineUnderstandingEngine(
        knowledge: <MedicineKnowledgeEntry>[
          MedicineKnowledgeEntry(
            name: 'Metformin XR',
            brand: 'Glyco XR',
            salt: 'Metformin Hydrochloride',
            strength: '500 mg',
            form: 'Tablet',
            aliases: <String>['SugarFix XR'],
          ),
        ],
      ).understand(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(text: 'SUGARFIX XR 500 mg\nTablets'),
      ]);

      expect(result.drafts, isNotEmpty);
      expect(result.drafts.single.name.toLowerCase(), contains('metformin'));
    });
  });
}
