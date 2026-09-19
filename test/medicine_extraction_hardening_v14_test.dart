import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_date_parser.dart' as date_parser;
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/spatial_traceability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V14', () {
    test('glued MFG/EXP labels repair bounded OCR digit confusions', () {
      final mfg = date_parser.extractMedicineDateMatches(
        'MFG.DATEO5O42O26',
        allowCompact: true,
      );
      final expiry = date_parser.extractMedicineDateMatches(
        'EXP.DATEO5O42O28',
        allowCompact: true,
      );

      expect(mfg.single.date.value, '2026-04-05');
      expect(expiry.single.date.value, '2028-04-05');

      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG.DATEO5O42O26\nEXP.DATEO5O42O28',
            quality: .95,
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

    test('punctuated batch label still vetoes a date-shaped value', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'B.No.O5O42O27', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );
      expect(result.manufacturing, isNull);
      expect(result.expiry, isNull);
    });

    test('label below a standalone date is understood without stealing next date', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG DATE\n05/04/2026\n05/04/2028\nEXPIRY DATE',
            quality: .95,
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

    test('date-label-date sandwich keeps preceding-label ownership', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: '05/04/2026\nEXPIRY DATE\n05/04/2028',
            quality: .95,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );
      expect(result.expiry?.date.value, '2028-04-05');
      expect(result.expiry!.explicitLabel, isTrue);
    });

    test('spatial resolver accepts a date printed immediately above EXP', () {
      final result = inferSpatialTraceability(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            quality: .95,
            layoutLines: <MedicineTextLineEvidence>[
              MedicineTextLineEvidence(
                text: '05/04/2028',
                left: 10,
                top: 20,
                width: 100,
                height: 10,
              ),
              MedicineTextLineEvidence(
                text: 'EXPIRY DATE',
                left: 10,
                top: 40,
                width: 80,
                height: 10,
              ),
            ],
          ),
        ],
      );
      expect(result.expiry?.value, '2028-04-05');
      expect(result.expiry!.confidence, greaterThanOrEqualTo(.80));
      expect(result.expiry!.conflicted, isFalse);
    });

    test('V2 keeps identity semantics while using mixed date placement', () {
      final frame = const MedicineFrameEvidence(
        text: 'DOLO 650\n'
            'COMPOSITION\n'
            'Paracetamol I.P. 650 mg\n'
            'MFG DATE\n'
            '05042026\n'
            '05042028\n'
            'EXPIRY DATE',
        sequence: 1,
        quality: .95,
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
