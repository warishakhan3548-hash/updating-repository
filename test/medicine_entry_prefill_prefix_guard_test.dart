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
  });
}
