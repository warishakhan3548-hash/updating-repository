import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/offline_evidence_graph.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V15', () {
    test('recovers an unlabeled pharmacopoeial ingredient and strength', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: '''NOVA CV
Amoxicillin Trihydrate I.P. 500 mg
Tablets''',
          quality: .95,
        ),
      ]);

      expect(result.components, hasLength(1));
      expect(
        result.components.single.ingredient.toLowerCase(),
        'amoxicillin trihydrate',
      );
      expect(result.components.single.strength, '500 mg');
      expect(result.compositionConfidence, greaterThanOrEqualTo(.90));
      expect(result.conflicted, isFalse);
    });

    test('does not reinterpret a plain trade name plus dose as composition', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(text: 'CROCIN 500 mg\nTablets', quality: .96),
      ]);

      expect(result.components, isEmpty);
      expect(result.salt, isEmpty);
    });

    test('price, pack, and country-of-origin noise cannot become ingredients', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: '''NOVA
Tablets
MRP Rs. 500 mg
10 TABLETS x 500 mg
Made in India 500 mg
BATCH AB500''',
          quality: .98,
        ),
      ]);

      expect(result.components, isEmpty);
      expect(result.salt, isEmpty);
    });

    test('geometry restores composition adjacency from scrambled OCR streams', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          quality: .96,
          layoutLines: <MedicineTextLineEvidence>[
            MedicineTextLineEvidence(
              text: 'Paracetamol I.P. 650 mg',
              left: 20,
              top: 60,
              width: 190,
              height: 18,
            ),
            MedicineTextLineEvidence(
              text: 'Tablets',
              left: 20,
              top: 84,
              width: 80,
              height: 16,
            ),
            MedicineTextLineEvidence(
              text: 'DOLO 650',
              left: 20,
              top: 10,
              width: 150,
              height: 24,
            ),
            MedicineTextLineEvidence(
              text: 'Composition',
              left: 20,
              top: 38,
              width: 120,
              height: 18,
            ),
          ],
        ),
      ]);

      expect(result.components, hasLength(1));
      expect(result.components.single.ingredient.toLowerCase(), 'paracetamol');
      expect(result.components.single.strength, '650 mg');
    });

    test('layout-only OCR remains an independent graph observation', () {
      final graph = buildOfflineEvidenceGraph(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 7,
          quality: .91,
          layoutLines: <MedicineTextLineEvidence>[
            MedicineTextLineEvidence(
              text: 'EXP 04/2028',
              left: 12,
              top: 20,
              width: 120,
              height: 18,
            ),
          ],
        ),
      ]);

      expect(graph.observedFrames, 1);
      expect(graph.independentObservations, 1);
      expect(graph.groups.single.representative.sequence, 7);
    });

    test('V2 keeps semantic recovery aligned with physical lot dates', () {
      const frame = MedicineFrameEvidence(
        text: '''NOVA CV
Amoxicillin Trihydrate I.P. 500 mg
Tablets
MFG 04/2026
EXP 04/2028''',
        sequence: 1,
        quality: .95,
      );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[frame.toMessage()],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
          'referenceDate': '2026-09-13T00:00:00.000Z',
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.salt.toLowerCase(), contains('amoxicillin'));
      expect(draft.strength.toLowerCase(), contains('500 mg'));
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });
  });
}
