import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V41', () {
    test('repairs only a truly fused liquid concentration', () {
      expect(
        normalizeMedicineOcrLine('PARACETAMOL I.P. 125mg5ml'),
        'PARACETAMOL I.P. 125 mg/5 ml',
      );
      expect(
        normalizeMedicineOcrLine('PARACETAMOL I.P. 125mg5m1'),
        'PARACETAMOL I.P. 125 mg/5 ml',
      );

      // A visible boundary can represent strength plus pack volume. Never join it.
      expect(
        normalizeMedicineOcrLine('PARACETAMOL I.P. 125 mg 5 ml'),
        'PARACETAMOL I.P. 125 mg 5 ml',
      );
      expect(
        normalizeMedicineOcrLine('BATCH NO 125mg5ml'),
        'BATCH NO 125mg5ml',
      );
    });

    test('canonicalizes only ingredient-owned combination separators', () {
      expect(
        normalizeMedicineOcrLine(
          'AMOXICILLIN I.P. 500 mg & CLAVULANIC ACID I.P. 125 mg',
        ),
        'AMOXICILLIN I.P. 500 mg + CLAVULANIC ACID I.P. 125 mg',
      );
      expect(
        normalizeMedicineOcrLine(
          'AMOXICILLIN I.P. 500 mg AND CLAVULANIC ACID I.P. 125 mg',
        ),
        'AMOXICILLIN I.P. 500 mg + CLAVULANIC ACID I.P. 125 mg',
      );
      expect(
        normalizeMedicineOcrLine(
          'AMOXICILLIN I.P. 500 mg WITH CLAVULANIC ACID I.P. 125 mg',
        ),
        'AMOXICILLIN I.P. 500 mg + CLAVULANIC ACID I.P. 125 mg',
      );
      expect(
        normalizeMedicineOcrLine('TAKE 500 mg AND 125 mg'),
        'TAKE 500 mg AND 125 mg',
      );
      expect(
        normalizeMedicineOcrLine('BATCH 500 mg & ABC 125 mg'),
        'BATCH 500 mg & ABC 125 mg',
      );
    });

    test('rewritten combination still obeys the dosage-instruction firewall', () {
      final line = normalizeMedicineOcrLine(
        'TAKE AMOXICILLIN I.P. 500 mg & CLAVULANIC ACID I.P. 125 mg TWICE DAILY',
      );
      final semantic = inferMedicineSemanticRoles(
        <MedicineFrameEvidence>[
          MedicineFrameEvidence(sequence: 41, quality: .99, text: line),
        ],
      );

      expect(semantic.components, isEmpty);
      expect(semantic.salt, isEmpty);
      expect(semantic.strength, isEmpty);
    });

    test('resolver V2 keeps fused syrup concentration as one strength', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 42,
              quality: .98,
              text: '''CALPOL PAEDIATRIC
PARACETAMOL I.P. 125mg5ml
ORAL SUSPENSION
MFG 04/2026
EXP 04/2028''',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('calpol'));
      expect(draft.brand.toLowerCase(), contains('calpol'));
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.strength.toLowerCase(), contains('125 mg/5 ml'));
      expect(draft.strength.toLowerCase(), isNot(contains('125 mg + 5 ml')));
      expect(draft.form, 'Suspension');
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });

    test('resolver V2 understands ampersand combination packs offline', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 43,
              quality: .98,
              text: '''AUGMENTIN 625 DUO
AMOXICILLIN I.P. 500 mg & CLAVULANIC ACID I.P. 125 mg
TABLETS
MFG 04/2026
EXP 04/2028''',
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
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });
  });
}
