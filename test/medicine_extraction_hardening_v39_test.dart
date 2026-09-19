import 'package:aaris_pharmacy/domain/medicine_confusion_firewall.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V39', () {
    test('same trade name with a critical variant is maximum confusion risk', () {
      final assessment = assessMedicineConfusion(
        const MedicineConfusionIdentity(
          name: 'CROCIN',
          salt: 'Paracetamol',
          strength: '500 mg',
          form: 'Tablet',
        ),
        const MedicineConfusionIdentity(
          name: 'CROCIN',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
      );

      expect(assessment.orthographicSimilarity, 1);
      expect(assessment.phoneticSimilarity, 1);
      expect(assessment.riskScore, 1);
      expect(assessment.criticalFields, contains('strength'));
      expect(assessment.highRisk, isTrue);
    });

    test('same complete identity is not treated as a confusion variant', () {
      final assessment = assessMedicineConfusion(
        const MedicineConfusionIdentity(
          name: 'DOLO',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
        const MedicineConfusionIdentity(
          name: 'DOLO',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
      );

      expect(assessment.riskScore, 0);
      expect(assessment.criticalFields, isEmpty);
      expect(assessment.highRisk, isFalse);
    });

    test('resolver V2 understands an unlabeled pack entirely offline', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 39,
              quality: .98,
              text: '''CROCIN ADVANCE
PARACETAMOL I.P.
650 mg
Tablets
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
      expect(draft.name.toLowerCase(), contains('crocin'));
      expect(draft.brand.toLowerCase(), contains('crocin'));
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.strength.toLowerCase(), contains('650'));
      expect(draft.form, 'Tablet');
      expect(draft.mfg, '2026-04-05');
      expect(draft.expiry, '2028-04-05');
    });
  });
}
