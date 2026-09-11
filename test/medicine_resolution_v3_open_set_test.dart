import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';

ExtractedMedicineField _f(String value, {double confidence = .95}) =>
    ExtractedMedicineField(
      value: value,
      confidence: confidence,
      support: 2,
      conflicted: false,
    );

MedicineScanDraft _draft(Map<String, ExtractedMedicineField> fields, String raw) =>
    MedicineScanDraft(
      fields: fields,
      rawText: raw,
      searchKeywords: raw,
      frameSequences: const <int>[0],
      overallConfidence: .95,
    );

void main() {
  group('Resolver V3 open-set behavior', () {
    test('unrelated packaging text does not force the nearest catalogue drug', () {
      const candidate = CanonicalMedicineProduct(
        productId: 'catalog:paracetamol:650',
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
          _draft(
            <String, ExtractedMedicineField>{
              'name': _f('HEALTH CARE PACK', confidence: .72),
              'form': _f('Tablet', confidence: .72),
            },
            'HEALTH CARE PACK\nSTORE BELOW 25 C\nTABLETS',
          ),
        ],
      );
      final resolved = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[candidate],
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            text: 'HEALTH CARE PACK\nSTORE BELOW 25 C\nTABLETS',
          ),
        ],
      );

      final draft = resolved.drafts.single;
      expect(draft.brand, isEmpty);
      expect(draft.salt, isEmpty);
      expect(draft.strength, isEmpty);
    });

    test('duplicate GTIN can resolve only with independent printed evidence', () {
      const gtin = '8901111111116';
      const candidates = <CanonicalMedicineProduct>[
        CanonicalMedicineProduct(
          productId: 'catalog:dolo:500',
          revision: 1,
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '500 mg',
          form: 'Tablet',
          barcodes: <String>[gtin],
          verified: true,
        ),
        CanonicalMedicineProduct(
          productId: 'catalog:dolo:650',
          revision: 2,
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
          barcodes: <String>[gtin],
          verified: true,
        ),
      ];
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          _draft(
            <String, ExtractedMedicineField>{
              'name': _f('Dolo'),
              'brand': _f('Dolo'),
              'salt': _f('Paracetamol'),
              'strength': _f('650 mg'),
              'form': _f('Tablet'),
              'barcode': _f(gtin, confidence: .995),
            },
            'DOLO 650\nParacetamol Tablets IP 650 mg\nTABLETS',
          ),
        ],
      );
      final resolved = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: candidates,
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            barcode: gtin,
            text: 'DOLO 650\nParacetamol Tablets IP 650 mg\nTABLETS',
          ),
        ],
      );

      final draft = resolved.drafts.single;
      expect(draft.strength, '650 mg');
      expect(draft.field('strength').conflicted, isFalse);
      expect(draft.overallConfidence, greaterThanOrEqualTo(.78));
    });
  });
}
