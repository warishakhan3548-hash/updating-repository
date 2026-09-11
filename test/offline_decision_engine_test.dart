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

    test('fuzzy product recovery cannot overwrite contradictory strength', () {
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

    test('shop memory gets the same resolver cascade without a model', () {
      const shop = MedicineKnowledgeEntry(
        name: 'Cardiwell',
        brand: 'Cardiwell',
        salt: '',
        strength: '40 mg',
        form: 'Tablet',
      );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              quality: .95,
              text: 'CARDXWELX 40 mg\nTABLETS',
            ).toMessage(),
          ],
          'knowledge': <Map<String, Object?>>[shop.toMessage()],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Cardiwell');
      expect(draft.brand, 'Cardiwell');
      expect(draft.strength.toLowerCase(), '40 mg');
      expect(draft.form, 'Tablet');
      expect(draft.field('strength').conflicted, isFalse);
      expect(draft.overallConfidence, greaterThanOrEqualTo(.78));
    });
  });
}
