import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';

void main() {
  group('Aaris deterministic offline decision engine', () {
    test('recovers a two-edit invented brand without an LLM or API', () {
      const product = CanonicalMedicineProduct(
        productId: 'offline:alphazine:500:tablet',
        revision: 600,
        name: 'Alphazine',
        brand: 'Alphazine',
        salt: '',
        strength: '500 mg',
        form: 'Tablet',
        verified: true,
        source: 'verified-offline-catalog',
      );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              quality: .95,
              text: 'A1PHAZLNE 500 mg\nTABLETS',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': <Map<String, Object?>>[product.toMessage()],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Alphazine');
      expect(draft.brand, 'Alphazine');
      expect(draft.strength.toLowerCase(), '500 mg');
      expect(draft.form, 'Tablet');
      expect(draft.field('strength').conflicted, isFalse);
      expect(draft.overallConfidence, greaterThanOrEqualTo(.78));
    });

    test('fuzzy product recovery exposes contradictory printed strength', () {
      const product = CanonicalMedicineProduct(
        productId: 'offline:alphazine:500:tablet',
        revision: 601,
        name: 'Alphazine',
        brand: 'Alphazine',
        salt: '',
        strength: '500 mg',
        form: 'Tablet',
        verified: true,
        source: 'verified-offline-catalog',
      );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              quality: .96,
              text: 'A1PHAZLNE 250 mg\nTABLETS',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': <Map<String, Object?>>[product.toMessage()],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.strength.toLowerCase(), '250 mg');
      expect(draft.field('strength').conflicted, isTrue);
      expect(draft.overallConfidence, lessThan(.78));
    });

    test('shop memory gets the same two-edit cascade without a model', () {
      const shop = MedicineKnowledgeEntry(
        name: 'Alphazine',
        brand: 'Alphazine',
        salt: '',
        strength: '500 mg',
        form: 'Tablet',
      );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              quality: .95,
              text: 'A1PHAZLNE 500 mg\nTABLETS',
            ).toMessage(),
          ],
          'knowledge': <Map<String, Object?>>[shop.toMessage()],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Alphazine');
      expect(draft.brand, 'Alphazine');
      expect(draft.strength.toLowerCase(), '500 mg');
      expect(draft.form, 'Tablet');
      expect(draft.field('strength').conflicted, isFalse);
      expect(draft.overallConfidence, greaterThanOrEqualTo(.78));
    });

    test('weak dosage-form corroboration cannot auto-lock fuzzy identity', () {
      const product = CanonicalMedicineProduct(
        productId: 'offline:alphazine:500:tablet',
        revision: 602,
        name: 'Alphazine',
        brand: 'Alphazine',
        salt: '',
        strength: '500 mg',
        form: 'Tablet',
        verified: true,
        source: 'verified-offline-catalog',
      );
      const observedName = ExtractedMedicineField(
        value: 'A1PHAZLNE',
        confidence: .94,
        support: 1,
        conflicted: false,
      );
      const observedForm = ExtractedMedicineField(
        value: 'Tablet',
        confidence: .95,
        support: 1,
        conflicted: false,
      );
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          const MedicineScanDraft(
            fields: <String, ExtractedMedicineField>{
              'name': observedName,
              'brand': observedName,
              'form': observedForm,
            },
            rawText: 'A1PHAZLNE\nTABLETS',
            searchKeywords: 'a1phazlne tablet',
            frameSequences: <int>[0],
            overallConfidence: .94,
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
            quality: .98,
            text: 'A1PHAZLNE\nTABLETS',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.name, 'A1PHAZLNE');
      expect(draft.strength, isEmpty);
      expect(draft.form, 'Tablet');
    });

    test('duplicate OCR frames cannot manufacture decision authority', () {
      const product = CanonicalMedicineProduct(
        productId: 'offline:alphazine:500:tablet',
        revision: 603,
        name: 'Alphazine',
        brand: 'Alphazine',
        salt: '',
        strength: '500 mg',
        form: 'Tablet',
        verified: true,
        source: 'verified-offline-catalog',
      );
      const observedName = ExtractedMedicineField(
        value: 'A1PHAZLNE',
        confidence: .94,
        support: 3,
        conflicted: false,
      );
      const observedForm = ExtractedMedicineField(
        value: 'Tablet',
        confidence: .95,
        support: 3,
        conflicted: false,
      );
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          const MedicineScanDraft(
            fields: <String, ExtractedMedicineField>{
              'name': observedName,
              'brand': observedName,
              'form': observedForm,
            },
            rawText: 'A1PHAZLNE\nTABLETS',
            searchKeywords: 'a1phazlne tablet',
            frameSequences: <int>[0, 1, 2],
            overallConfidence: .94,
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
            quality: .98,
            text: 'A1PHAZLNE\nTABLETS',
          ),
          MedicineFrameEvidence(
            sequence: 1,
            quality: .98,
            text: 'A1PHAZLNE\nTABLETS',
          ),
          MedicineFrameEvidence(
            sequence: 2,
            quality: .98,
            text: 'A1PHAZLNE\nTABLETS',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.name, 'A1PHAZLNE');
      expect(draft.strength, isEmpty);
    });
  });
}
