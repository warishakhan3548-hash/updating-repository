import 'package:aaris_pharmacy/domain/regulatory_medicine_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('regulatory GTIN hardening', () {
    test('valid GS1 Digital Link keeps canonical product identity', () {
      final parsed = parseRegulatoryMedicineCode(
        'https://example.org/01/09504000059118/10/LOT7?17=271031',
      );

      expect(parsed, isNotNull);
      expect(parsed!.gtin, '09504000059118');
      expect(parsed.batchLot, 'LOT7');
      expect(parsed.expiryYyMmDd, '271031');
    });

    test('decorated Digital Link GTIN cannot become trusted identity', () {
      final parsed = parseRegulatoryMedicineCode(
        'https://example.org/01/promo09504000059118x/10/LOT7',
      );

      expect(parsed, isNull);
    });

    test('labelled payload does not strip letters around a GTIN', () {
      final parsed = parseRegulatoryMedicineCode(
        'GTIN: ABC09504000059118; BATCH: LOT7',
      );

      expect(parsed, isNull);
    });

    test('labelled valid GTIN remains accepted', () {
      final parsed = parseRegulatoryMedicineCode(
        'GTIN: 09504000059118; BATCH: LOT7',
      );

      expect(parsed, isNotNull);
      expect(parsed!.gtin, '09504000059118');
      expect(parsed.batchLot, 'LOT7');
    });
  });
}
