import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_ocr_reliability.dart';

void main() {
  test('zero detector confidence is unavailable rather than bad OCR', () {
    expect(usableMedicineOcrConfidence(0), isNull);
    expect(usableMedicineOcrConfidence(0.0), isNull);
    expect(usableMedicineOcrConfidence(null), isNull);
  });

  test('positive detector confidence is safely bounded', () {
    expect(usableMedicineOcrConfidence(.73), .73);
    expect(usableMedicineOcrConfidence(2), 1);
  });

  test('non-finite detector confidence stays unavailable', () {
    expect(usableMedicineOcrConfidence(double.nan), isNull);
    expect(usableMedicineOcrConfidence(double.infinity), isNull);
    expect(usableMedicineOcrConfidence(double.negativeInfinity), isNull);
  });
}
