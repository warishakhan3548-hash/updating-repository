import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V36', () {
    test('strong fused semantic roles are casing independent', () {
      expect(
        normalizeMedicineOcrLine('BrandNameCalpol'),
        'BRAND NAME Calpol',
      );
      expect(
        normalizeMedicineOcrLine('genericnameparacetamol500mgTablets'),
        'GENERIC NAME paracetamol 500mg Tablets',
      );
      expect(
        normalizeMedicineOcrLine('ManufacturerNameCipla'),
        'MANUFACTURER Cipla',
      );
      expect(
        normalizeMedicineOcrLine('manufacturernamecipla'),
        'MANUFACTURER cipla',
      );
    });

    test('bare role-like product words remain untouched', () {
      expect(normalizeMedicineOcrLine('BrandNew'), 'BrandNew');
      expect(normalizeMedicineOcrLine('GenericMedicine'), 'GenericMedicine');
      expect(normalizeMedicineOcrLine('Productivity500mg'), 'Productivity 500mg');
    });

    test('resolver V2 recovers a mixed-case fused pack without any AI provider', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 36,
              quality: .98,
              text: '''BrandNameCalpol
GenericNameParacetamol500mgTablets
MfgApr2026
ExpApr2028
ManufacturerNameGlaxoPharmaLtd
BatchNoAB123''',
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
