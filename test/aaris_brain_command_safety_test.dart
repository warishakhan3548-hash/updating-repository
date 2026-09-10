import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine_brief.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain intent firewall', () {
    test('negated inventory writes never become actions', () {
      for (final command in [
        'Dolo 650 delete mat karo',
        "don't sell Dolo 650",
        'Dolo 650 ko remove nahi karna',
        'डोलो को डिलीट मत करो',
        'undo mat karo',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
        expect(
          intent.safetyReason,
          AppBrainSafetyReason.negatedMutation,
          reason: command,
        );
        expect(intent.mutatesInventory, isFalse, reason: command);
        expect(intent.destructive, isFalse, reason: command);
      }
    });

    test(
      'conditional and future writes fail closed instead of running now',
      () {
        for (final command in [
          'if stock is zero delete Dolo 650',
          'Dolo 650 kal sell karna',
          'jab stock low ho Dolo remove karo',
          'Dolo 650 restore later',
          'Dolo 650 sell at 5 pm',
          'what if I delete Dolo 650?',
        ]) {
          final intent = parseAppBrainIntent(command);
          expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
          expect(
            intent.safetyReason,
            AppBrainSafetyReason.deferredMutation,
            reason: command,
          );
          expect(intent.mutatesInventory, isFalse, reason: command);
        }
      },
    );

    test('compound inventory writes are never partially executed', () {
      for (final command in [
        'Dolo 650 delete or mark sold',
        'Dolo 650 stock add 5 units then location Rack B set karo',
        'Dolo 650 quantity 10 set karo then sell 2 units',
        'Dolo 650 edit then remove',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
        expect(
          intent.safetyReason,
          AppBrainSafetyReason.compoundMutation,
          reason: command,
        );
        expect(intent.mutatesInventory, isFalse, reason: command);
      }
    });

    test('safe operational reads keep their existing deterministic routes', () {
      final fefo = parseAppBrainIntent('Dolo 650 sell which batch first');
      expect(fefo.action, AppBrainAction.search);
      expect(fefo.briefFocus, MedicineBriefFocus.fefo);
      expect(fefo.mutatesInventory, isFalse);

      final stock = parseAppBrainIntent('Dolo 650 stock kitna hai');
      expect(stock.action, AppBrainAction.search);
      expect(stock.briefFocus, MedicineBriefFocus.stock);
      expect(stock.mutatesInventory, isFalse);
    });

    test('polite positive requests still enter the reviewed action path', () {
      final intent = parseAppBrainIntent('Can you please delete Dolo 650?');
      expect(intent.action, AppBrainAction.removeMedicine);
      expect(intent.query, 'Dolo 650');
      expect(intent.safetyReason, isNull);
      expect(intent.destructive, isTrue);
    });

    test(
      'bulk delete stays protected while negated bulk delete does nothing',
      () {
        final protected = parseAppBrainIntent('delete all medicines');
        expect(protected.action, AppBrainAction.bulkRemoveBlocked);

        final negated = parseAppBrainIntent('delete all medicines mat karo');
        expect(negated.action, AppBrainAction.safetyBlocked);
        expect(negated.safetyReason, AppBrainSafetyReason.negatedMutation);
      },
    );
  });

  group('Human-like exact context grammar', () {
    test(
      'natural English Hinglish and Hindi references remain exact-context only',
      () {
        for (final phrase in [
          'that medicine',
          'that stock entry',
          'woh wali medicine',
          'us medicine me',
          'उस मेडिसिन को',
          'वही दवा',
          'previous one',
        ]) {
          expect(isAppBrainContextReference(phrase), isTrue, reason: phrase);
        }
      },
    );

    test(
      'context cleanup does not turn ordinary medicine names into pronouns',
      () {
        for (final phrase in [
          'Dolo 650',
          'Usman 500',
          'Sameer Tablet',
          'Thatol 20',
        ]) {
          expect(isAppBrainContextReference(phrase), isFalse, reason: phrase);
        }
      },
    );

    test(
      'natural delete sentence preserves exact previous-context semantics',
      () {
        final hinglish = parseAppBrainIntent(
          'mujhe us medicine ko delete karna hai',
        );
        expect(hinglish.action, AppBrainAction.removeMedicine);
        expect(isAppBrainContextReference(hinglish.query), isTrue);

        final hindi = parseAppBrainIntent('मुझे उस मेडिसिन को डिलीट करना है');
        expect(hindi.action, AppBrainAction.removeMedicine);
        expect(isAppBrainContextReference(hindi.query), isTrue);
      },
    );

    test('contextual stock receipt can use natural reference grammar', () {
      final intent = parseAppBrainIntent('that medicine stock add 5 units');
      expect(intent.action, AppBrainAction.receiveStock);
      expect(intent.quantity, 5);
      expect(isAppBrainContextReference(intent.query), isTrue);
    });
  });

  test('next-task wording routes to the dependency-aware operating plan', () {
    for (final command in [
      'next task',
      'do next task',
      'agla kaam',
      'अब क्या करना है',
    ]) {
      final intent = parseAppBrainIntent(command);
      expect(intent.action, AppBrainAction.nextAttentionTask, reason: command);
      expect(intent.mutatesInventory, isFalse, reason: command);
      expect(intent.destructive, isFalse, reason: command);
    }
  });
}
