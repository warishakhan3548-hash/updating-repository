import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V17', () {
    test('split batch label vetoes a date-shaped lot value', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'BATCH\n05042027\nEXPIRY DATE\n05042028',
            quality: .95,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing, isNull);
      expect(result.expiry?.date.value, '2028-04-05');
      expect(result.expiry?.explicitLabel, isTrue);
      expect(result.conflicted, isFalse);
    });

    test('explicit date role outranks an adjacent non-date heading', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG DATE\n05042026\nBATCH\nAB123\nEXP DATE\n05042028',
            quality: .95,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing?.date.value, '2026-04-05');
      expect(result.expiry?.date.value, '2028-04-05');
      expect(result.manufacturing?.explicitLabel, isTrue);
      expect(result.expiry?.explicitLabel, isTrue);
      expect(result.conflicted, isFalse);
    });

    test('two bare compact month-year values form a cautious chronology', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '042026\n042028', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing?.date.value, '2026-04');
      expect(result.expiry?.date.value, '2028-04');
      expect(result.manufacturing!.confidence, greaterThanOrEqualTo(.78));
      expect(result.expiry!.confidence, greaterThanOrEqualTo(.78));
      expect(result.conflicted, isFalse);
    });

    test('bare compact singleton stays non-authoritative', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '042028', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing, isNull);
      expect(result.expiry, isNull);
    });

    test('three bare compact values stay ambiguous instead of auto-filling', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '042026\n122026\n042028', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing, isNull);
      expect(result.expiry, isNull);
    });

    test('V2 recovers raw OCR identity plus an unlabeled month-year pair', () {
      const frame = MedicineFrameEvidence(
        text: 'DOLO 650\n'
            'COMPOSITION\n'
            'Paracetamol I.P. 650 mg\n'
            '042026\n'
            '042028',
        quality: .95,
        sequence: 1,
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
    });
  });
}
