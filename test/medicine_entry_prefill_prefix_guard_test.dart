import 'package:aaris_pharmacy/domain/medicine_entry_prefill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('quick intake field-label boundaries', () {
    test('field-label prefixes inside medicine names remain medicine evidence', () {
      final rowName = parseMedicineAddPrefill('add medicine Rowatinex 10')!;
      expect(rowName.name, 'Rowatinex 10');
      expect(rowName.row, isEmpty);

      final brandName = parseMedicineAddPrefill('add medicine Branded 10')!;
      expect(brandName.name, 'Branded 10');
      expect(brandName.brand, isEmpty);

      final barcodeName = parseMedicineAddPrefill('add medicine BarcodeX 20')!;
      expect(barcodeName.name, 'BarcodeX 20');
      expect(barcodeName.barcode, isEmpty);

      final shelfName = parseMedicineAddPrefill('add medicine ShelfAid 20')!;
      expect(shelfName.name, 'ShelfAid 20');
      expect(shelfName.location, isEmpty);
    });

    test('labeled fact words cannot be captured from medicine-name suffixes', () {
      final citrate = parseMedicineAddPrefill(
        'add medicine Potassium Citrate 10',
      )!;
      expect(citrate.name, 'Potassium Citrate 10');
      expect(citrate.priceText, isEmpty);

      final qtySuffix = parseMedicineAddPrefill('add medicine Xqty 20')!;
      expect(qtySuffix.name, 'Xqty 20');
      expect(qtySuffix.quantity, isNull);
    });

    test('unlabeled units are never guessed as physical stock quantity', () {
      final draft = parseMedicineAddPrefill('add medicine Insulin 10 units')!;
      expect(draft.name, 'Insulin 10 units');
      expect(draft.quantity, isNull);

      final explicit = parseMedicineAddPrefill(
        'add medicine Insulin qty 10 units',
      )!;
      expect(explicit.name, 'Insulin');
      expect(explicit.quantity, 10);
    });

    test('real labeled fields still parse only with a delimiter', () {
      final draft = parseMedicineAddPrefill(
        'add medicine Rowatinex row R2 brand ACME barcode ABC123 shelf A1',
      )!;
      expect(draft.name, 'Rowatinex');
      expect(draft.row, 'R2');
      expect(draft.brand, 'ACME');
      expect(draft.barcode, 'ABC123');
      expect(draft.location, 'A1');
    });

    test('Devanagari price digits are normalized only when explicitly labeled', () {
      final draft = parseMedicineAddPrefill(
        'नई दवा Crocin price १२.५० qty ५',
      )!;
      expect(draft.name, 'Crocin');
      expect(draft.priceText, '12.50');
      expect(draft.quantity, 5);
    });
  });
}
