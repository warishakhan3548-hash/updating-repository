import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine adjacent label ownership V20', () {
    test('preceding batch label vetoes a date-shaped token before EXP', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'BATCH\n04/2028\nEXP',
            quality: .98,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.isEmpty, isTrue);
    });

    test('preceding EXP still owns the date when a later batch label exists', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'EXP\n04/2028\nBATCH',
            quality: .98,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 13),
      );

      expect(result.expiry?.date.value, '2028-04');
      expect(result.expiry?.explicitLabel, isTrue);
      expect(result.conflicted, isFalse);
    });
  });
}
