import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_date_parser.dart' as date_parser;
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V13', () {
    test('separator-less full dates stay usable for chronological pairs', () {
      final first = date_parser.extractMedicineDateMatches(
        '05042026',
        allowCompact: true,
      );
      final second = date_parser.extractMedicineDateMatches(
        '05042028',
        allowCompact: true,
      );

      expect(first.single.date.value, '2026-04-05');
      expect(second.single.date.value, '2028-04-05');
      expect(first.single.compact, isFalse);
      expect(second.single.compact, isFalse);

      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '05042026\n05042028'),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing?.date.value, '2026-04-05');
      expect(result.expiry?.date.value, '2028-04-05');
      expect(result.manufacturing!.confidence, greaterThanOrEqualTo(.78));
      expect(result.expiry!.confidence, greaterThanOrEqualTo(.78));
      expect(result.conflicted, isFalse);
    });

    test('OCR digit confusions also work in separator-less full dates', () {
      final match = date_parser.extractMedicineDateMatches(
        'O5O42O28',
        allowCompact: true,
      );
      expect(match.single.date.value, '2028-04-05');
      expect(match.single.compact, isFalse);
    });

    test('six-digit compact month-year still requires date context', () {
      final match = date_parser.extractMedicineDateMatches(
        '052028',
        allowCompact: true,
      );
      expect(match.single.date.value, '2028-05');
      expect(match.single.compact, isTrue);

      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '052028'),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );
      expect(result.manufacturing, isNull);
      expect(result.expiry, isNull);
    });

    test('non-date labels veto full-date-shaped batch values', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'BATCH 05042027'),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );
      expect(result.manufacturing, isNull);
      expect(result.expiry, isNull);
    });

    test('V2 resolves raw OCR identity, strength and unlabeled compact dates', () {
      final frame = const MedicineFrameEvidence(
        text: 'DOLO 650\nCOMPOSITION\nParacetamol I.P. 650 mg\n05042026\n05042028',
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
