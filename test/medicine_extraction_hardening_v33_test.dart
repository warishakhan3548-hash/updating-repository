import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V33', () {
    test('glued medicine doses recover only at pharmaceutical unit boundaries', () {
      expect(
        normalizeMedicineOcrLine('Paracetamol5O0MG'),
        'Paracetamol 500MG',
      );
      expect(normalizeMedicineOcrLine('CALPOL500MG'), 'CALPOL 500MG');
      expect(normalizeMedicineOcrLine('VitaminB12'), 'VitaminB12');
    });

    test('glued date and traceability roles regain their semantic boundary', () {
      expect(
        normalizeMedicineOcrLine('MFG04/2026 EXP04/2028'),
        'MFG 04/2026 EXP 04/2028',
      );
      expect(
        normalizeMedicineOcrLine('BATCHNOABC850MG'),
        'BATCH NO ABC850MG',
      );
      expect(normalizeMedicineOcrLine('LOTABC500MG'), 'LOT ABC500MG');
    });

    test('resolver V2 recovers fused OCR without promoting batch digits to dose', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 33,
              quality: .97,
              text: 'CALPOL500MG\nParacetamol5O0MG\nTABLETS\nMFG04/2026\nEXP04/2028\nBATCHNOABC850MG',
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
      expect(draft.strength.toLowerCase(), isNot(contains('850')));
      expect(draft.batchNumber, 'ABC850MG');
      expect(draft.form, 'Tablet');
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });
  });
}
