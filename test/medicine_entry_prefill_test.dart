import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine_entry_prefill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain reviewed medicine quick intake', () {
    test('extracts explicit stock facts into a review-only draft', () {
      final intent = parseAppBrainIntent(
        'add medicine Dolo 650 qty 20 exp 2027-05 batch AB12 shelf A1 price 12.50',
      );

      expect(intent.action, AppBrainAction.addMedicine);
      final draft = intent.addPrefill!;
      expect(draft.name, 'Dolo 650');
      expect(draft.quantity, 20);
      expect(draft.expiry, '2027-05');
      expect(draft.expiryMonthOnly, isTrue);
      expect(draft.batchNumber, 'AB12');
      expect(draft.location, 'A1');
      expect(draft.priceText, '12.50');
      expect(intent.mutatesInventory, isFalse);
    });

    test('understands Devanagari digits without guessing new facts', () {
      final draft = parseMedicineAddPrefill(
        'नई दवा Crocin qty ५ expiry २०२७-०५',
      )!;

      expect(draft.name, 'Crocin');
      expect(draft.quantity, 5);
      expect(draft.expiry, '2027-05');
      expect(draft.strength, isEmpty);
      expect(draft.salt, isEmpty);
    });

    test('extracts typed strength form and structured physical location', () {
      final draft = parseMedicineAddPrefill(
        'add medicine Amox strength 500mg form capsule qty 30 block B1 row R3 vertical V4',
      )!;

      expect(draft.name, 'Amox');
      expect(draft.strength, '500mg');
      expect(draft.form, 'Capsule');
      expect(draft.quantity, 30);
      expect(draft.block, 'B1');
      expect(draft.row, 'R3');
      expect(draft.vertical, 'V4');
    });

    test(
      'unit-bearing strength can be extracted but bare 650 is never stock',
      () {
        final unitStrength = parseMedicineAddPrefill(
          'add medicine Amox 500mg capsule qty 10',
        )!;
        expect(unitStrength.name, 'Amox');
        expect(unitStrength.strength.toLowerCase(), '500mg');
        expect(unitStrength.form, 'Capsule');
        expect(unitStrength.quantity, 10);

        final bare = parseMedicineAddPrefill('add medicine Dolo 650')!;
        expect(bare.name, 'Dolo 650');
        expect(bare.quantity, isNull);
        expect(bare.strength, isEmpty);
      },
    );

    test('explicit multi-word evidence requires quotes and remains bounded', () {
      final draft = parseMedicineAddPrefill(
        'add medicine Dolo location "Cold Cabinet 2" manufacturer "ACME Pharma"',
      )!;
      expect(draft.name, 'Dolo');
      expect(draft.location, 'Cold Cabinet 2');
      expect(draft.manufacturer, 'ACME Pharma');
    });

    test('invalid or contradictory explicit facts fail closed', () {
      expect(
        () => parseMedicineAddPrefill('add medicine Dolo expiry 2027-99 qty 5'),
        throwsFormatException,
      );
      expect(
        () => parseMedicineAddPrefill('add medicine Dolo qty 5 quantity 6'),
        throwsFormatException,
      );
      expect(
        () => parseMedicineAddPrefill('add medicine Dolo price 9999999999.00'),
        throwsFormatException,
      );
    });

    test('plain add command preserves the existing blank-editor workflow', () {
      final intent = parseAppBrainIntent('add medicine');
      expect(intent.action, AppBrainAction.addMedicine);
      expect(intent.addPrefill, isNotNull);
      expect(intent.addPrefill!.isEmpty, isTrue);
    });
  });
}
