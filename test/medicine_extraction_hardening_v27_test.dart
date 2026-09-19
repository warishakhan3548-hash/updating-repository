import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_date_parser.dart';
import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V27', () {
    test('OCR boundary canonicalizes multiscript strength evidence', () {
      expect(
        mergeMedicineOcrLines(<String>[
          'PARACETAMOL I.P. ५०० ｍｇ',
          'PARACETAMOL I.P. 500 mg',
        ]),
        <String>['PARACETAMOL I.P. 500 mg'],
      );
      expect(
        mergeMedicineOcrLines(<String>['BUDESONIDE I.P. ٠٫٥ μg']),
        <String>['BUDESONIDE I.P. 0.5 ug'],
      );
    });

    test('unit-bound O I L repair never invents a numeric strength', () {
      expect(
        mergeMedicineOcrLines(<String>['AMOXICILLIN I.P. 5OO mg']),
        <String>['AMOXICILLIN I.P. 500 mg'],
      );
      expect(mergeMedicineOcrLines(<String>['OIL mg']), <String>['OIL mg']);
      expect(mergeMedicineOcrLines(<String>['ILL IU']), <String>['ILL IU']);
    });

    test('full-width product text reaches semantic brand and salt reasoning', () {
      final text = mergeMedicineOcrLines(<String>[
        'ＣＲＯＣＩＮ',
        'PARACETAMOL I.P. ５OO ｍｇ',
        'TABLETS',
      ]).join('\n');

      final semantic = inferMedicineSemanticRoles(<MedicineFrameEvidence>[
        MedicineFrameEvidence(text: text, quality: .85),
      ]);

      expect(semantic.brand, 'CROCIN');
      expect(semantic.salt, 'PARACETAMOL');
      expect(semantic.strength, '500 mg');
      expect(semantic.conflicted, isFalse);
    });

    test('compact MMYY is syntax only until role evidence owns it', () {
      final mfg = extractMedicineDateMatches(
        'MFG O426',
        allowCompact: true,
      );
      final exp = extractMedicineDateMatches(
        'EXP O428',
        allowCompact: true,
      );

      expect(mfg, hasLength(1));
      expect(mfg.single.date.value, '2026-04');
      expect(mfg.single.compact, isTrue);
      expect(exp, hasLength(1));
      expect(exp.single.date.value, '2028-04');
      expect(exp.single.compact, isTrue);
    });

    test('two isolated compact MMYY values infer a safe MFG EXP chronology', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '0426\n0428', quality: .85),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );

      expect(result.manufacturing?.date.value, '2026-04');
      expect(result.expiry?.date.value, '2028-04');
      expect(result.conflicted, isFalse);
    });

    test('compact MMYY singleton and lot-owned values fail closed', () {
      final singleton = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '0428', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(singleton.isEmpty, isTrue);

      final lotOwned = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'LOT 0426\n0428', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(lotOwned.isEmpty, isTrue);
    });
  });
}
