import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V37', () {
    test('fused date roles recover when first month digit is OCR-confusable', () {
      expect(
        normalizeMedicineOcrLine('MFGO4/2026 EXPI2/2028'),
        'MFG O4/2026 EXP I2/2028',
      );
      expect(
        normalizeMedicineOcrLine('MfgO4-26 ExpI2-28'),
        'Mfg O4-26 Exp I2-28',
      );
      expect(
        normalizeMedicineOcrLine('MFGORANGE2026'),
        'MFGORANGE2026',
      );
    });

    test('resolver V2 repairs role-owned O/I month glyphs without AI', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 37,
              quality: .98,
              text: '''BrandNameCalpol
GenericNameParacetamol500mgTablets
MFGO4/2026
EXPI2/2028
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
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.strength.toLowerCase(), contains('500'));
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-12');
      expect(draft.batchNumber, 'AB123');
    });
  });
}
