import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';

void main() {
  group('Aaris deterministic offline decision engine', () {
    test('recovers a two-edit OCR product without an LLM or API', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:azithromycin:500:tablet',
        revision: 600,
        name: 'Azithromycin',
        brand: 'Azithromycin',
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
              quality: .93,
              text: 'AZYTHROMYCXN 500 mg\nTABLETS',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': <Map<String, Object?>>[product.toMessage()],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Azithromycin');
      expect(draft.brand, 'Azithromycin');
      expect(draft.strength.toLowerCase(), '500 mg');
      expect(draft.form, 'Tablet');
      expect(draft.field('strength').conflicted, isFalse);
      expect(draft.overallConfidence, greaterThanOrEqualTo(.78));
    });

    test('two-edit recovery cannot overwrite contradictory printed strength', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:azithromycin:500:tablet',
        revision: 601,
        name: 'Azithromycin',
        brand: 'Azithromycin',
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
              text: 'AZYTHROMYCXN 250 mg\nTABLETS',
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

    test('shop memory also benefits from the multi-stage fuzzy cascade', () {
      const shop = MedicineKnowledgeEntry(
        name: 'Telmisartan',
        brand: 'Telmisartan',
        salt: '',
        strength: '40 mg',
        form: 'Tablet',
      );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              quality: .92,
              text: 'TELMXSARTXN 40 mg\nTABLETS',
            ).toMessage(),
          ],
          'knowledge': <Map<String, Object?>>[shop.toMessage()],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Telmisartan');
      expect(draft.strength.toLowerCase(), '40 mg');
      expect(draft.form, 'Tablet');
      expect(draft.needsReview, isFalse);
    });
  });
}
