import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/spatial_traceability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V18', () {
    test('merged two-column date rows keep MFG and EXP ownership', () {
      final result = inferSpatialTraceability(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            quality: .97,
            layoutLines: <MedicineTextLineEvidence>[
              MedicineTextLineEvidence(
                text: 'MFG DATE       EXP DATE',
                left: 10,
                top: 20,
                width: 320,
                height: 18,
              ),
              MedicineTextLineEvidence(
                text: '04/2026       04/2028',
                left: 10,
                top: 48,
                width: 320,
                height: 18,
              ),
            ],
          ),
        ],
      );

      expect(result.mfg?.value, '2026-04');
      expect(result.expiry?.value, '2028-04');
      expect(result.mfg?.conflicted, isFalse);
      expect(result.expiry?.conflicted, isFalse);
    });

    test('one printed date token cannot be consumed by two date labels', () {
      final result = inferSpatialTraceability(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            quality: .96,
            layoutLines: <MedicineTextLineEvidence>[
              MedicineTextLineEvidence(
                text: 'MFG',
                left: 10,
                top: 10,
                width: 45,
                height: 18,
              ),
              MedicineTextLineEvidence(
                text: 'EXP',
                left: 10,
                top: 70,
                width: 45,
                height: 18,
              ),
              MedicineTextLineEvidence(
                text: '04/2028',
                left: 10,
                top: 40,
                width: 76,
                height: 18,
              ),
            ],
          ),
        ],
      );

      final resolved = <String>[
        if (result.mfg != null) result.mfg!.value,
        if (result.expiry != null) result.expiry!.value,
      ];
      expect(resolved, hasLength(1));
      expect(resolved.single, '2028-04');
    });

    test('V2 keeps identity while resolving a merged spatial date panel', () {
      const frame = MedicineFrameEvidence(
        text: 'DOLO 650\nCOMPOSITION\nParacetamol I.P. 650 mg\nTablets',
        sequence: 3,
        quality: .97,
        layoutLines: <MedicineTextLineEvidence>[
          MedicineTextLineEvidence(
            text: 'DOLO 650',
            left: 10,
            top: 5,
            width: 150,
            height: 26,
          ),
          MedicineTextLineEvidence(
            text: 'MFG DATE       EXP DATE',
            left: 10,
            top: 100,
            width: 320,
            height: 18,
          ),
          MedicineTextLineEvidence(
            text: '04/2026       04/2028',
            left: 10,
            top: 128,
            width: 320,
            height: 18,
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
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
      expect(draft.field('mfg').conflicted, isFalse);
      expect(draft.field('expiry').conflicted, isFalse);
    });
  });
}
