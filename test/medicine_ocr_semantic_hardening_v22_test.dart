import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_date_parser.dart';
import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

MedicineScanDraft _draft(String text) => MedicineUnderstandingEngine()
    .understand(<MedicineFrameEvidence>[
      MedicineFrameEvidence(text: text, quality: .98),
    ])
    .drafts
    .single;

void main() {
  group('medicine OCR semantic hardening V22', () {
    test('dosage forms remain semantically distinct', () {
      expect(
        _draft('ZIFI\nCefixime 100 mg/5 ml\nORAL SUSPENSION').form,
        'Suspension',
      );
      expect(
        _draft('LEVOSALBUTAMOL\nLevosalbutamol 1 mg/5 ml\nORAL SOLUTION')
            .form,
        'Solution',
      );
      expect(_draft('DICLOFENAC\nDiclofenac 1% w/w\nGEL').form, 'Gel');
      expect(
        _draft('ASTHALIN\nSalbutamol 100 mcg/dose\nINHALER').form,
        'Inhaler',
      );
    });

    test('extended pharmaceutical strengths survive extraction', () {
      expect(
        _draft('DICLOFENAC\nDiclofenac 1% w/w\nGEL').strength,
        '1% w/w',
      );
      expect(
        _draft('ASTHALIN\nSalbutamol 100 mcg/dose\nINHALER').strength,
        '100 mcg/dose',
      );
      expect(
        _draft('POTASSIUM CHLORIDE\nPotassium Chloride 20 mEq/15 ml').strength,
        '20 meq/15 ml',
      );
    });

    test('common manufacturer and dotted MRP labels are recognized', () {
      final draft = _draft(
        'CROCIN\nParacetamol 500 mg\nMFG. BY: ACME PHARMA PVT LTD\nM.R.P. Rs. 123.50',
      );
      expect(draft.manufacturer, contains('ACME PHARMA'));
      expect(draft.printedMrp, '₹123.50');
    });

    test('semantic role parser understands denominator strengths', () {
      final result = inferMedicineSemanticRoles(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'SALMETEROL\nSalmeterol 50 mcg/dose\nINHALER',
            quality: .96,
          ),
        ],
      );
      expect(result.salt.toLowerCase(), contains('salmeterol'));
      expect(result.strength, '50 mcg/dose');
    });

    test('DOM and DOE are authoritative date labels', () {
      expect(medicineManufacturingLabel.hasMatch('DOM 04/2026'), isTrue);
      expect(medicineExpiryLabel.hasMatch('DOE 04/2028'), isTrue);
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'DOM 04/2026\nDOE 04/2028',
            quality: .96,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );
      expect(result.manufacturing?.date.value, '2026-04');
      expect(result.expiry?.date.value, '2028-04');
      expect(result.conflicted, isFalse);
    });

    test('packing dates are quarantined from MFG and EXP roles', () {
      expect(medicineNonDateLabel.hasMatch('PKD 04/2026'), isTrue);
      expect(medicineNonDateLabel.hasMatch('DATE OF PACKING 04/2026'), isTrue);
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'PKD 04/2026\nEXP 04/2028',
            quality: .96,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );
      expect(result.manufacturing, isNull);
      expect(result.expiry?.date.value, '2028-04');
    });

    test('numeric OCR repair handles uppercase L and invisible marks', () {
      expect(parseMedicineDateText('EXP 0L/2028')?.value, '2028-01');
      expect(
        parseMedicineDateText('EXP\u200F 04/2028')?.value,
        '2028-04',
      );
    });

    test('OCR dedupe and quality support non-Latin decimal digits', () {
      expect(
        mergeMedicineOcrLines(<String>[
          'EXP\u200F 04/2028',
          'EXP 04/2028',
        ]),
        <String>['EXP 04/2028'],
      );
      expect(medicineOcrLineQuality('EXP ٠٤/٢٠٢٨'), greaterThan(.5));
      expect(medicineOcrLineQuality('EXP ۰۴/۲۰۲۸'), greaterThan(.5));
    });
  });
}
