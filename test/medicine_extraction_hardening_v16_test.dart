import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V16', () {
    test('layout date roles follow physical geometry, not recognizer insertion order', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            quality: .96,
            layoutLines: <MedicineTextLineEvidence>[
              // Deliberately scrambled to emulate merged Latin/Devanagari
              // recognizer streams. Bounding boxes contain the true order.
              MedicineTextLineEvidence(
                text: 'EXPIRY DATE',
                left: 16,
                top: 70,
                width: 100,
                height: 14,
              ),
              MedicineTextLineEvidence(
                text: 'MFG DATE',
                left: 16,
                top: 10,
                width: 90,
                height: 14,
              ),
              MedicineTextLineEvidence(
                text: '05/04/2028',
                left: 16,
                top: 92,
                width: 100,
                height: 14,
              ),
              MedicineTextLineEvidence(
                text: '05/04/2026',
                left: 16,
                top: 32,
                width: 100,
                height: 14,
              ),
            ],
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing?.date.value, '2026-04-05');
      expect(result.expiry?.date.value, '2028-04-05');
      expect(result.manufacturing!.explicitLabel, isTrue);
      expect(result.expiry!.explicitLabel, isTrue);
      expect(result.conflicted, isFalse);
    });

    test('same-row date panels are ordered left to right before role binding', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            quality: .94,
            layoutLines: <MedicineTextLineEvidence>[
              MedicineTextLineEvidence(
                text: '04/2028',
                left: 310,
                top: 40,
                width: 72,
                height: 14,
              ),
              MedicineTextLineEvidence(
                text: 'EXP',
                left: 230,
                top: 40,
                width: 45,
                height: 14,
              ),
              MedicineTextLineEvidence(
                text: '04/2026',
                left: 90,
                top: 40,
                width: 72,
                height: 14,
              ),
              MedicineTextLineEvidence(
                text: 'MFG',
                left: 15,
                top: 40,
                width: 45,
                height: 14,
              ),
            ],
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing?.date.value, '2026-04');
      expect(result.expiry?.date.value, '2028-04');
      expect(result.conflicted, isFalse);
    });

    test('V2 preserves identity while geometry repairs MFG and EXP ownership', () {
      const frame = MedicineFrameEvidence(
        text: 'DOLO 650\nCOMPOSITION\nParacetamol I.P. 650 mg',
        quality: .96,
        sequence: 4,
        layoutLines: <MedicineTextLineEvidence>[
          MedicineTextLineEvidence(
            text: 'EXPIRY DATE',
            left: 12,
            top: 160,
            width: 110,
            height: 14,
          ),
          MedicineTextLineEvidence(
            text: 'MFG DATE',
            left: 12,
            top: 110,
            width: 90,
            height: 14,
          ),
          MedicineTextLineEvidence(
            text: '05 04 2028',
            left: 12,
            top: 180,
            width: 100,
            height: 14,
          ),
          MedicineTextLineEvidence(
            text: '05 04 2026',
            left: 12,
            top: 130,
            width: 100,
            height: 14,
          ),
        ],
      );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[frame.toMessage()],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
          'referenceDate': '2026-09-13T00:00:00.000Z',
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('dolo'));
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.strength.toLowerCase(), contains('650 mg'));
      expect(draft.mfg, '2026-04-05');
      expect(draft.expiry, '2028-04-05');
    });
  });
}
