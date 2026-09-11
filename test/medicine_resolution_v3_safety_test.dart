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

MedicineScanDraft _draft({
  required Map<String, ExtractedMedicineField> fields,
  String rawText = 'Captured medicine evidence',
  double overallConfidence = .95,
}) => MedicineScanDraft(
  fields: fields,
  rawText: rawText,
  searchKeywords: rawText,
  frameSequences: const <int>[0],
  overallConfidence: overallConfidence,
);

const _sameGtin = '8901111111116';

void main() {
  group('Resolver V3 safety hardening', () {
    test('duplicate verified GTIN never invents one product from barcode alone', () {
      const products = <CanonicalMedicineProduct>[
        CanonicalMedicineProduct(
          productId: 'catalog:dolo:500',
          revision: 1,
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '500 mg',
          form: 'Tablet',
          barcodes: <String>[_sameGtin],
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
          barcodes: <String>[_sameGtin],
          verified: true,
        ),
      ];
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          _draft(
            fields: <String, ExtractedMedicineField>{
              'barcode': _field(_sameGtin, confidence: .995),
            },
            rawText: _sameGtin,
            overallConfidence: .55,
          ),
        ],
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: products,
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            barcode: _sameGtin,
            text: _sameGtin,
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.name, isEmpty);
      expect(draft.brand, isEmpty);
      expect(draft.strength, isEmpty);
      expect(draft.overallConfidence, lessThan(.78));
    });

    test('GS1 disagreement with credible OCR is visible instead of overwritten', () {
      const gs1 = ']d2010890123456789010LOT7\u001d1126081517280731';
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          _draft(
            fields: <String, ExtractedMedicineField>{
              'name': _field('Testmed'),
              'brand': _field('Testmed'),
              'salt': _field('Paracetamol'),
              'strength': _field('650 mg'),
              'form': _field('Tablet'),
              'expiry': _field('2028-08-31', confidence: .90),
            },
          ),
        ],
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[],
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(sequence: 0, barcode: gs1, text: 'TESTMED'),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.expiry, '2028-07-31');
      expect(draft.field('expiry').conflicted, isTrue);
      expect(draft.overallConfidence, lessThan(.78));
    });

    test('month-only OCR agrees with a GS1 date in the same month', () {
      const gs1 = ']d2010890123456789010LOT7\u001d1126081517280731';
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          _draft(
            fields: <String, ExtractedMedicineField>{
              'expiry': _field('2028-07', confidence: .90),
            },
            rawText: 'EXP 07/2028',
          ),
        ],
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[],
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(sequence: 0, barcode: gs1, text: 'EXP 07/2028'),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.expiry, '2028-07-31');
      expect(draft.field('expiry').conflicted, isFalse);
    });

    test('impossible GS1 manufacturing-after-expiry fails closed', () {
      const gs1 = ']d2010890123456789010LOT7\u001d1129010117280731';
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          _draft(
            fields: <String, ExtractedMedicineField>{
              'name': _field('Testmed'),
              'brand': _field('Testmed'),
              'salt': _field('Paracetamol'),
              'strength': _field('650 mg'),
              'form': _field('Tablet'),
            },
          ),
        ],
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[],
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(sequence: 0, barcode: gs1, text: 'TESTMED'),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.mfg, '2029-01-01');
      expect(draft.expiry, '2028-07-31');
      expect(draft.field('mfg').conflicted, isTrue);
      expect(draft.field('expiry').conflicted, isTrue);
      expect(draft.overallConfidence, lessThan(.78));
    });
  });
}
