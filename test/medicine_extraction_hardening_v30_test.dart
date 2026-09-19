import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V30', () {
    test('preposed liquid composition basis is bound to the ingredient dose', () {
      expect(
        normalizeMedicineOcrLine(
          'Each 5 millilitres contains Paracetamol I.P. 1 2 5 milligrams',
        ),
        'Each 5 ml contains; Paracetamol I.P. 125 mg/5 ml',
      );
      expect(
        normalizeMedicineOcrLine(
          'Each 5 g contains Clotrimazole I.P. 10 milligrams',
        ),
        'Each 5 g contains; Clotrimazole I.P. 10 mg/5 g',
      );
    });

    test('already explicit concentration is never denominatorized twice', () {
      final normalized = normalizeMedicineOcrLine(
        'Each 5 ml contains Paracetamol 125 mg / 5 ml',
      );
      expect(normalized, contains('125 mg / 5 ml'));
      expect(normalized, isNot(contains('/5 ml/5 ml')));
      expect(normalized, isNot(contains('/ 5 ml/5 ml')));
    });

    test('ordinary volume and pack prose does not invent a concentration', () {
      expect(
        normalizeMedicineOcrLine('Take 5 ml after food'),
        'Take 5 ml after food',
      );
      expect(
        normalizeMedicineOcrLine('Bottle contains 60 ml'),
        'Bottle contains 60 ml',
      );
    });

    test('semantic roles keep liquid basis out of ingredient identity', () {
      final text = mergeMedicineOcrLines(<String>[
        'CALPOL',
        'Each 5 ml contains Paracetamol I.P. 125 mg',
        'ORAL SUSPENSION',
      ]).join('\n');
      final semantic = inferMedicineSemanticRoles(<MedicineFrameEvidence>[
        MedicineFrameEvidence(text: text, quality: .94),
      ]);

      expect(semantic.brand.toLowerCase(), contains('calpol'));
      expect(semantic.salt.toLowerCase(), contains('paracetamol'));
      expect(semantic.salt.toLowerCase(), isNot(contains('5 ml paracetamol')));
      expect(semantic.strength.toLowerCase(), contains('125 mg/5 ml'));
      expect(semantic.conflicted, isFalse);
    });

    test('multi-ingredient suspension inherits the same explicit 5 ml basis', () {
      final text = mergeMedicineOcrLines(<String>[
        'AUGMENTIN',
        'Each 5 ml of reconstituted suspension contains Amoxicillin Trihydrate I.P. 200 mg + Clavulanic Acid I.P. 28.5 mg',
      ]).join('\n');
      final semantic = inferMedicineSemanticRoles(<MedicineFrameEvidence>[
        MedicineFrameEvidence(text: text, quality: .95),
      ]);

      expect(semantic.salt.toLowerCase(), contains('amoxicillin trihydrate'));
      expect(semantic.salt.toLowerCase(), contains('clavulanic acid'));
      expect(semantic.strength.toLowerCase(), contains('200 mg/5 ml'));
      expect(semantic.strength.toLowerCase(), contains('28.5 mg/5 ml'));
      expect(semantic.conflicted, isFalse);
    });

    test('resolver V2 carries the liquid basis through the final review draft', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 30,
              quality: .95,
              text: 'CALPOL\nEach 5 ml contains Paracetamol I.P. 125 mg\nORAL SUSPENSION\nMFG 05/2026\nEXP 04/2028',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('calpol'));
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.strength.toLowerCase(), contains('125 mg/5 ml'));
      expect(draft.form, 'Suspension');
      expect(draft.mfg, '2026-05');
      expect(draft.expiry, '2028-04');
    });
  });
}
