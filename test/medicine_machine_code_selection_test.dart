import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_machine_code_safety.dart';

void main() {
  test('different trusted product codes are quarantined from exact resolution', () {
    final selection = selectSafeMedicineMachineCodes(const <String>[
      '09504000059118',
      '09501101530003',
      'https://example.invalid/promo',
    ]);

    expect(selection.ambiguousTrustedProductCodes, isTrue);
    expect(selection.payloads, isEmpty);
    expect(selection.assessment.trustedProductKeys, hasLength(2));
  });

  test('same GTIN across linear and DataMatrix forms stays usable', () {
    final selection = selectSafeMedicineMachineCodes(const <String>[
      '9504000059118',
      ']d201095040000591181727103110LOT7',
    ]);

    expect(selection.ambiguousTrustedProductCodes, isFalse);
    expect(selection.assessment.singleTrustedProduct, '09504000059118');
    expect(selection.payloads, contains('09504000059118'));
    expect(selection.payloads, contains(']d201095040000591181727103110LOT7'));
  });

  test('promo QR can coexist with one medicine code without blocking it', () {
    final selection = selectSafeMedicineMachineCodes(const <String>[
      'https://example.invalid/promo',
      '09504000059118',
    ]);

    expect(selection.ambiguousTrustedProductCodes, isFalse);
    expect(selection.payloads.first, '09504000059118');
  });
}
