import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V29', () {
    test('numeric-unit OCR fragmentation canonicalizes without touching prose', () {
      expect(
        normalizeMedicineOcrLine('PARACETAMOL 1 0 0 0 milligrams'),
        'PARACETAMOL 1000 mg',
      );
      expect(
        normalizeMedicineOcrLine('AMOXICILLIN 125 mg per 5 millilitres'),
        'AMOXICILLIN 125 mg/5 ml',
      );
      expect(
        normalizeMedicineOcrLine('BUDESONIDE 0 . 5 micrograms'),
        'BUDESONIDE 0.5 mcg',
      );
      expect(
        normalizeMedicineOcrLine('SUSPENSION 5 m1'),
        'SUSPENSION 5 ml',
      );
      expect(
        normalizeMedicineOcrLine('Take one tablet per day'),
        'Take one tablet per day',
      );
      expect(normalizeMedicineOcrLine('OIL milligrams'), 'OIL milligrams');
    });

    test('thousands separator is not downgraded into a decimal strength', () {
      expect(
        normalizeMedicineOcrLine('PARACETAMOL 1,000 mg'),
        'PARACETAMOL 1000 mg',
      );
      expect(
        normalizeMedicineOcrLine('BUDESONIDE 0,500 mg'),
        'BUDESONIDE 0,500 mg',
      );
    });

    test('equivalent OCR unit surfaces collapse to one evidence line', () {
      expect(
        mergeMedicineOcrLines(<String>[
          'AMOXICILLIN 125 mg per 5 millilitres',
          'AMOXICILLIN 125 mg/5 ml',
          'AMOXICILLIN 125 mg/5 ml',
        ]),
        <String>['AMOXICILLIN 125 mg/5 ml'],
      );
    });

    test('unlabelled word-unit OCR still resolves brand and composition', () {
      final text = mergeMedicineOcrLines(<String>[
        'AUGMENTIN',
        'AMOXICILLIN TRIHYDRATE I.P. 2 0 0 milligrams',
        'CLAVULANIC ACID I.P. 28 . 5 milligrams per 5 millilitres',
        'ORAL SUSPENSION',
      ]).join('\n');

      final semantic = inferMedicineSemanticRoles(<MedicineFrameEvidence>[
        MedicineFrameEvidence(text: text, quality: .90),
      ]);

      expect(semantic.brand, 'AUGMENTIN');
      expect(semantic.salt.toLowerCase(), contains('amoxicillin trihydrate'));
      expect(semantic.salt.toLowerCase(), contains('clavulanic acid'));
      expect(semantic.strength, contains('200 mg'));
      expect(semantic.strength, contains('28.5 mg/5 ml'));
      expect(semantic.conflicted, isFalse);
    });
  });
}
