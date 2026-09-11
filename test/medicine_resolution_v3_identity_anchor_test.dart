import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';

ExtractedMedicineField _field(String value, {double confidence = .95}) =>
    ExtractedMedicineField(
      value: value,
      confidence: confidence,
      support: 2,
      conflicted: false,
    );

void main() {
  group('Resolver V3 identity anchor', () {
    test('generic salt dose and form never invent a trade brand', () {
      const product = CanonicalMedicineProduct(
        productId: 'catalog:dolo:650',
        revision: 1,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        manufacturer: 'Micro Labs',
        verified: true,
      );
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          MedicineScanDraft(
            fields: <String, ExtractedMedicineField>{
              'salt': _field('Paracetamol'),
              'strength': _field('650 mg'),
              'form': _field('Tablet'),
            },
            rawText: 'Paracetamol Tablets IP 650 mg\nTABLETS',
            searchKeywords: 'paracetamol 650 mg tablet',
            frameSequences: const <int>[0],
            overallConfidence: .95,
          ),
        ],
      );

      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[product],
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            text: 'Paracetamol Tablets IP 650 mg\nTABLETS',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.name, isEmpty);
      expect(draft.brand, isEmpty);
      expect(draft.salt, 'Paracetamol');
      expect(draft.strength, '650 mg');
      expect(draft.form, 'Tablet');
    });

    test('strong printed OCR alias can anchor a verified trade product', () {
      const product = CanonicalMedicineProduct(
        productId: 'catalog:dolo:650',
        revision: 2,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        ocrAliases: <String>['D0L0'],
        verified: true,
      );
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          MedicineScanDraft(
            fields: <String, ExtractedMedicineField>{
              'salt': _field('Paracetamol'),
              'strength': _field('650 mg'),
              'form': _field('Tablet'),
            },
            rawText: 'D0L0 65O\nParacetamol Tablets IP 650 mg\nTABLETS',
            searchKeywords: 'd0l0 paracetamol 650 mg tablet',
            frameSequences: const <int>[0],
            overallConfidence: .82,
          ),
        ],
      );

      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[product],
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            text: 'D0L0 65O\nParacetamol Tablets IP 650 mg\nTABLETS',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Dolo');
      expect(draft.brand, 'Dolo');
      expect(draft.strength, '650 mg');
      expect(draft.field('brand').conflicted, isFalse);
    });
  });
}
