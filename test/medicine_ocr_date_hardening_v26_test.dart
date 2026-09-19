import 'package:aaris_pharmacy/domain/medicine_date_parser.dart';
import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine OCR/date hardening V26', () {
    test('pure O I L words are never repaired into compact numeric dates', () {
      expect(
        extractMedicineDateMatches('OIL LOLL ILL', allowCompact: true),
        isEmpty,
      );
      expect(parseMedicineDateText('OIL'), isNull);
    });

    test('mixed OCR digit confusions still recover a real compact full date', () {
      final parsed = parseMedicineDateText('MFG O5O42O27');
      expect(parsed?.value, '2027-04-05');
      expect(parsed?.monthOnly, isFalse);
    });

    test('glued alphabetic month dates remain recoverable but role-unsafe', () {
      final full = extractMedicineDateMatches(
        '05APR2027',
        allowCompact: true,
      );
      expect(full, hasLength(1));
      expect(full.single.date.value, '2027-04-05');
      expect(full.single.compact, isTrue);

      final monthOnly = extractMedicineDateMatches(
        'APR2028',
        allowCompact: true,
      );
      expect(monthOnly, hasLength(1));
      expect(monthOnly.single.date.value, '2028-04');
      expect(monthOnly.single.compact, isTrue);
    });

    test('common abbreviated production and use-up-to labels are recognized', () {
      expect(medicineManufacturingLabel.hasMatch('PROD DT 05/04/2027'), isTrue);
      expect(medicineExpiryLabel.hasMatch('USE UP TO 04/2028'), isTrue);
      expect(medicineExpiryLabel.hasMatch('USE UPTO 04/2028'), isTrue);
    });

    test('glued labels own compact dates and bounded O I OCR repair', () {
      final production = parseMedicineDateText('PRODDTO5O42O27');
      expect(production?.value, '2027-04-05');
      expect(production?.monthOnly, isFalse);

      final expiry = parseMedicineDateText('USEUPTOO42O28');
      expect(expiry?.value, '2028-04');
      expect(expiry?.monthOnly, isTrue);

      // An arbitrary alphabetic prefix is still not a date-valued context.
      expect(parseMedicineDateText('SERIALO5O42O27'), isNull);
    });

    test('invisible OCR format marks cannot split medicine identity tokens', () {
      expect(medicineOcrLineKey('PARA\u00ADCETAMOL'), 'paracetamol');
      expect(medicineOcrLineKey('CRO\u034FCIN'), 'crocin');
      expect(medicineOcrLineKey('AZI\u061CTHROMYCIN'), 'azithromycin');
      expect(
        mergeMedicineOcrLines(<String>[
          'PARA\u00ADCETAMOL 500 mg',
          'PARACETAMOL 500 mg',
        ]),
        <String>['PARACETAMOL 500 mg'],
      );
    });
  });
}
