import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V34', () {
    test('named-month date roles recover when OCR glues the label', () {
      expect(
        normalizeMedicineOcrLine('MFGAPR2026 EXPIRYDEC 2028'),
        'MFG APR2026 EXPIRY DEC 2028',
      );
      expect(
        normalizeMedicineOcrLine('EXPANSION2028 VitaminB12'),
        'EXPANSION2028 VitaminB12',
      );
    });

    test('strong semantic labels and owner roles regain value boundaries', () {
      expect(
        normalizeMedicineOcrLine(
          'BRANDNAMECALPOL GENERICNAMEPARACETAMOL500MGTablets',
        ),
        'BRAND NAME CALPOL GENERIC NAME PARACETAMOL 500MG Tablets',
      );
      expect(
        normalizeMedicineOcrLine('MANUFACTUREDBYGLAXO PHARMA LTD'),
        'MANUFACTURED BY GLAXO PHARMA LTD',
      );
      expect(normalizeMedicineOcrLine('BrandNew'), 'BrandNew');
    });

    test('fully glued liquid composition keeps its printed denominator', () {
      expect(
        normalizeMedicineOcrLine('EACH10MLCONTAINSParacetamol250MG'),
        'EACH 10 ml contains; Paracetamol 250MG/10 ml',
      );
    });

    test('dose-to-form recovery reuses canonical form vocabulary safely', () {
      expect(
        normalizeMedicineOcrLine('CALPOL500MGTablets'),
        'CALPOL 500MG Tablets',
      );
      expect(
        normalizeMedicineOcrLine('BATCHNOABC850MGTablets'),
        'BATCH NO ABC850MG Tablets',
      );
    });

    test('resolver V2 extracts a heavily fused pack without any AI provider', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 34,
              quality: .98,
              text: 'BRANDNAMECALPOL\nGENERICNAMEPARACETAMOL500MGTablets\nMFGAPR2026\nEXPAPR2028\nMANUFACTUREDBYGLAXO PHARMA LTD\nBATCHNOAB123',
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
      expect(draft.strength.toLowerCase(), contains('500'));
      expect(draft.form, 'Tablet');
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
      expect(draft.manufacturer.toLowerCase(), contains('glaxo'));
      expect(draft.batchNumber, 'AB123');
    });
  });
}
