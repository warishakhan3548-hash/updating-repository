import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V38', () {
    test('compact confusable month roles regain their field boundary', () {
      expect(
        normalizeMedicineOcrLine('MFGO42026 EXPI22028'),
        'MFG O42026 EXP I22028',
      );
      expect(
        normalizeMedicineOcrLine('MFGORANGE2026'),
        'MFGORANGE2026',
      );
    });

    test('fused batch number aliases canonicalize without touching payload', () {
      expect(normalizeMedicineOcrLine('BATCHNUMBERAB123'), 'BATCH NO AB123');
      expect(normalizeMedicineOcrLine('LOTNUMZX-77'), 'LOT NO ZX-77');
      expect(
        normalizeMedicineOcrLine('BATCHNOABC850MGTablets'),
        'BATCH NO ABC850MG Tablets',
      );
    });

    test('resolver V2 extracts compact dates and fused batch number offline', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 38,
              quality: .98,
              text: '''BrandNameCalpol
GenericNameParacetamol500mgTablets
MFGO42026
EXPI22028
BATCHNUMBERAB123''',
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
