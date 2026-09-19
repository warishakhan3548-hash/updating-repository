import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V40', () {
    test('unlabeled combination row keeps ingredients aligned to strengths', () {
      final semantic = inferMedicineSemanticRoles(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 40,
            quality: .98,
            text: '''AUGMENTIN 625 DUO
AMOXICILLIN I.P. 500 mg + CLAVULANIC ACID I.P. 125 mg
TABLETS''',
          ),
        ],
      );

      expect(semantic.components, hasLength(2));
      expect(semantic.salt.toLowerCase(), contains('amoxicillin'));
      expect(semantic.salt.toLowerCase(), contains('clavulanic acid'));
      expect(semantic.strength, contains('500 mg'));
      expect(semantic.strength, contains('125 mg'));
      expect(semantic.brand.toLowerCase(), contains('augmentin'));
      expect(semantic.brand.toLowerCase(), isNot(contains('amoxicillin')));
    });

    test('dosage instructions cannot masquerade as unlabeled composition', () {
      final semantic = inferMedicineSemanticRoles(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 41,
            quality: .99,
            text:
                'TAKE AMOXICILLIN I.P. 500 mg + CLAVULANIC ACID I.P. 125 mg TWICE DAILY',
          ),
        ],
      );

      expect(semantic.components, isEmpty);
      expect(semantic.salt, isEmpty);
      expect(semantic.strength, isEmpty);
    });

    test('resolver V2 understands an unlabeled combination pack offline', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 42,
              quality: .98,
              text: '''AUGMENTIN 625 DUO
AMOXICILLIN I.P. 500 mg + CLAVULANIC ACID I.P. 125 mg
TABLETS
05042026
05042028''',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('augmentin'));
      expect(draft.brand.toLowerCase(), contains('augmentin'));
      expect(draft.salt.toLowerCase(), contains('amoxicillin'));
      expect(draft.salt.toLowerCase(), contains('clavulanic acid'));
      expect(draft.strength, contains('500 mg'));
      expect(draft.strength, contains('125 mg'));
      expect(draft.form, 'Tablet');
      expect(draft.mfg, '2026-04-05');
      expect(draft.expiry, '2028-04-05');
    });
  });
}
