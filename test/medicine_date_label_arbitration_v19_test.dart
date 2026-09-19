import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine date label arbitration V19', () {
    test('closer reverse EXP outranks older preceding MFG label', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG SOME EXTRA TEXT 04/2028 EXP',
            quality: .97,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.manufacturing, isNull);
      expect(result.expiry?.date.value, '2028-04');
      expect(result.expiry?.explicitLabel, isTrue);
      expect(result.expiry!.confidence, greaterThan(.94));
      expect(result.conflicted, isFalse);
    });

    test('distant preceding non-date label cannot hide nearby reverse EXP', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text:
                'LOT ABCDEFGHIJKLMNOPQRSTUVWXYZ ABCDEFGHIJKLMNOPQRSTUVWXYZ 04/2028 EXP',
            quality: .96,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.expiry?.date.value, '2028-04');
      expect(result.expiry?.explicitLabel, isTrue);
      expect(result.conflicted, isFalse);
    });

    test('nearby LOT still owns its numeric token over a farther reverse EXP', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'LOT 04/2028 EXP', quality: .98),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.isEmpty, isTrue);
    });
  });
}
