import 'package:aaris_pharmacy/domain/medicine_date_parser.dart';
import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V44', () {
    test('canonicalizes only strong semantic field roles', () {
      expect(
        normalizeMedicineOcrLine(
          'ACTIVEINGREDIENTNAMEPARACETAMOL650MG',
        ),
        'ACTIVE INGREDIENT PARACETAMOL 650MG',
      );
      expect(
        normalizeMedicineOcrLine(
          'ACTIVE-INGREDIENT-NAME: PARACETAMOL 650 mg',
        ),
        'ACTIVE INGREDIENT: PARACETAMOL 650 mg',
      );
      expect(
        normalizeMedicineOcrLine('MANUFACTURER_NAME: FDC LIMITED'),
        'MANUFACTURER: FDC LIMITED',
      );
      expect(
        normalizeMedicineOcrLine('PRODUCT-NAME: CROCIN 650'),
        'PRODUCT NAME: CROCIN 650',
      );
      expect(
        normalizeMedicineOcrLine('SALT_NAME: PARACETAMOL'),
        'GENERIC NAME: PARACETAMOL',
      );
      expect(
        normalizeMedicineOcrLine('PROPRIETARYNAMECROCIN'),
        'PROPRIETARY NAME CROCIN',
      );
      expect(
        normalizeMedicineOcrLine('TRADEMARKCROCIN'),
        'TRADE MARK CROCIN',
      );

      // Bare prefixes are intentionally still not semantic roles. Splitting
      // arbitrary product words would create more false positives than recall.
      expect(normalizeMedicineOcrLine('BRANDCROCIN'), 'BRANDCROCIN');
      expect(normalizeMedicineOcrLine('SALTSHAKER'), 'SALTSHAKER');
    });

    test('parses Hindi named months with script digits', () {
      expect(
        parseMedicineDateText('निर्माण तिथि: अप्रैल २०२६')?.value,
        '2026-04',
      );
      expect(
        parseMedicineDateText('समाप्ति तिथि: अप्रैल २०२८')?.value,
        '2028-04',
      );
      expect(
        parseMedicineDateText('MFG ०५ अप्रैल २०२६')?.value,
        '2026-04-05',
      );
      expect(
        parseMedicineDateText('EXP २०२८ अप्रैल')?.value,
        '2028-04',
      );
    });

    test('resolver V2 uses recovered roles and Hindi dates offline', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 44,
              quality: .98,
              text: '''PRODUCT-NAME: CROCIN 650
ACTIVEINGREDIENTNAMEPARACETAMOL650MG
TABLETS
MANUFACTURER_NAME: GSK PHARMA
निर्माण तिथि: अप्रैल २०२६
समाप्ति तिथि: अप्रैल २०२८''',
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
      expect(draft.salt.toLowerCase(), isNot(contains('name')));
      expect(draft.strength.toLowerCase(), contains('650 mg'));
      expect(draft.form, 'Tablet');
      expect(draft.manufacturer.toLowerCase(), contains('gsk'));
      expect(draft.manufacturer.toLowerCase(), isNot(contains('name')));
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });
  });
}
