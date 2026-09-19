import 'package:aaris_pharmacy/services/medicine_review_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine review local-AI contention policy', () {
    test('backs off exponentially without hot spinning', () {
      expect(
        medicineReviewContentionDelay(0),
        const Duration(milliseconds: 40),
      );
      expect(
        medicineReviewContentionDelay(1),
        const Duration(milliseconds: 80),
      );
      expect(
        medicineReviewContentionDelay(2),
        const Duration(milliseconds: 160),
      );
      expect(
        medicineReviewContentionDelay(3),
        const Duration(milliseconds: 320),
      );
      expect(
        medicineReviewContentionDelay(7),
        const Duration(milliseconds: 320),
      );
    });

    test('fails closed after the bounded contention budget', () {
      expect(medicineReviewContentionDelay(-1), isNull);
      expect(medicineReviewContentionDelay(8), isNull);
      expect(medicineReviewContentionDelay(100), isNull);
    });

    test('total retry wait remains bounded', () {
      final delays = List<Duration>.generate(
        8,
        (index) => medicineReviewContentionDelay(index)!,
      );
      final total = delays.fold<int>(
        0,
        (sum, delay) => sum + delay.inMilliseconds,
      );
      expect(total, 1880);
    });
  });
}
