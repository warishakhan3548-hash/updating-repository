import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_date_parser.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine date edge cases V21', () {
    test('large OCR column gap cannot synthesize a cross-column date', () {
      final matches = extractMedicineDateMatches(
        '04/2026       04/2028',
        allowCompact: true,
      );

      expect(matches.map((match) => match.date.value).toList(), <String>[
        '2026-04',
        '2028-04',
      ]);
    });

    test('single bare 8-digit token is not promoted to a date role', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: '05042027', quality: .95),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing, isNull);
      expect(result.expiry, isNull);
    });

    test('coherent bare 8-digit pair can recover MFG and EXP chronology', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: '05042026\n05042028',
            quality: .95,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing?.date.value, '2026-04-05');
      expect(result.expiry?.date.value, '2028-04-05');
      expect(result.conflicted, isFalse);
    });

    test('explicit compact MFG remains authoritative', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'MFG 05042027', quality: .95),
        ],
        referenceDate: DateTime.utc(2027, 5, 1),
      );

      expect(result.manufacturing?.date.value, '2027-04-05');
    });
  });
}
