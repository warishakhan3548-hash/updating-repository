import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine_brief.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain removed-stock recovery intents', () {
    test('targeted restore opens reviewed recovery for the requested medicine', () {
      final intent = parseAppBrainIntent('Dolo 650 restore karo');
      expect(intent.action, AppBrainAction.restoreMedicine);
      expect(intent.query, 'Dolo 650');
      expect(intent.confidence, greaterThanOrEqualTo(.99));
      expect(intent.needsMedicineTarget, isTrue);
      expect(intent.mutatesInventory, isTrue);
      expect(intent.destructive, isFalse);
    });

    test('contextual restore preserves the pronoun for exact session resolution', () {
      for (final command in [
        'restore it',
        'restore isko',
        'isko restore karo',
        'इसे रिस्टोर करो',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.restoreMedicine, reason: command);
        expect(
          isAppBrainContextReference(intent.query),
          isTrue,
          reason: command,
        );
        expect(intent.mutatesInventory, isTrue, reason: command);
        expect(intent.destructive, isFalse, reason: command);
      }
    });

    test('targetless removed-stock language opens recovery history only', () {
      for (final command in [
        'removed stock dikhao',
        'deleted medicines',
        'रिमूव्ड स्टॉक',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(
          intent.action,
          AppBrainAction.removedStockReview,
          reason: command,
        );
        expect(intent.query, isEmpty, reason: command);
        expect(intent.mutatesInventory, isFalse, reason: command);
        expect(intent.destructive, isFalse, reason: command);
      }
    });

    test('backup restore wording can never become medicine restore', () {
      for (final command in [
        'restore backup',
        'backup restore',
        'बैकअप रिस्टोर',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.navigate, reason: command);
        expect(intent.section, AppSection.profile, reason: command);
        expect(intent.mutatesInventory, isFalse, reason: command);
      }
    });
  });

  group('Aaris Brain natural dispensing intents', () {
    test('plain pharmacist sell command enters the existing reviewed sale path', () {
      final intent = parseAppBrainIntent('Dolo 650 sell');
      expect(intent.action, AppBrainAction.recordSale);
      expect(intent.query, 'Dolo 650');
      expect(intent.quantity, isNull);
      expect(intent.destructive, isTrue);
    });

    test('explicit units are separated from strength before FEFO planning', () {
      final english = parseAppBrainIntent('Dolo 650 5 units sell');
      expect(english.action, AppBrainAction.recordSale);
      expect(english.query, 'Dolo 650');
      expect(english.quantity, 5);

      final hindi = parseAppBrainIntent('Dolo 650 ५ यूनिट बेच दो');
      expect(hindi.action, AppBrainAction.recordSale);
      expect(hindi.query, 'Dolo 650');
      expect(hindi.quantity, 5);
    });

    test('FEFO questions containing sell or dispense remain read-only', () {
      for (final command in [
        'Dolo 650 sell which batch first',
        'Dolo 650 dispense which batch first',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.search, reason: command);
        expect(intent.query, 'Dolo 650', reason: command);
        expect(intent.briefFocus, MedicineBriefFocus.fefo, reason: command);
        expect(intent.destructive, isFalse, reason: command);
        expect(intent.mutatesInventory, isFalse, reason: command);
      }
    });

    test('question-shaped sell language never creates a sale intent', () {
      final intent = parseAppBrainIntent('Dolo 650 sell how much?');
      expect(intent.action, isNot(AppBrainAction.recordSale));
      expect(intent.mutatesInventory, isFalse);
    });
  });
}
