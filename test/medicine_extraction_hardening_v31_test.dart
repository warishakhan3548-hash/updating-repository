import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V31', () {
    test('liquid basis stops before a flattened dose instruction', () {
      expect(
        normalizeMedicineOcrLine(
          'Each 5 ml contains Paracetamol I.P. 125 mg. Dose 250 mg after food',
        ),
        'Each 5 ml contains; Paracetamol I.P. 125 mg/5 ml. Dose 250 mg after food',
      );
    });

    test('composition role parser cannot turn a dose into an ingredient', () {
      final text = mergeMedicineOcrLines(<String>[
        'CALPOL',
        'Each 5 ml contains Paracetamol I.P. 125 mg. Dose 250 mg after food',
        'ORAL SUSPENSION',
      ]).join('\n');
      final semantic = inferMedicineSemanticRoles(<MedicineFrameEvidence>[
        MedicineFrameEvidence(text: text, quality: .95),
      ]);

      expect(semantic.salt.toLowerCase(), contains('paracetamol'));
      expect(semantic.salt.toLowerCase(), isNot(contains('dose')));
      expect(semantic.strength.toLowerCase(), contains('125 mg/5 ml'));
      expect(semantic.strength.toLowerCase(), isNot(contains('250 mg')));
      expect(semantic.conflicted, isFalse);
    });

    test('two compact dates flattened onto one row infer chronology safely', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '0426 0428', quality: .92),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );

      expect(result.manufacturing?.date.value, '2026-04');
      expect(result.expiry?.date.value, '2028-04');
      expect(result.conflicted, isFalse);
    });

    test('flattened compact date inference still rejects owned or noisy IDs', () {
      final lotOwned = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'LOT 0426 0428', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(lotOwned.isEmpty, isTrue);

      final threeTokens = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '0426 0428 1234', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(threeTokens.isEmpty, isTrue);
    });

    test('resolver V2 survives merged instructions and unlabeled compact dates', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 31,
              quality: .95,
              text: 'CALPOL\nEach 5 ml contains Paracetamol I.P. 125 mg. Dose 250 mg after food\nORAL SUSPENSION\n0426 0428',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.salt.toLowerCase(), isNot(contains('dose')));
      expect(draft.strength.toLowerCase(), contains('125 mg/5 ml'));
      expect(draft.strength.toLowerCase(), isNot(contains('250 mg')));
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });
  });
}
