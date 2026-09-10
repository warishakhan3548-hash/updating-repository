import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/warning_policy.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Future<PharmacyController> makeController() async {
  final controller = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  group('Aaris Brain expiry-policy control plane', () {
    test(
      'parses explicit unit-bound warning policy in English and Hindi digits',
      () {
        final combined = parseAppBrainIntent(
          'short expiry warning 10 days and month expiry 3 months set karo',
        );
        expect(combined.action, AppBrainAction.setWarningPolicy);
        expect(combined.warningPolicy?.shortDays, 10);
        expect(combined.warningPolicy?.months, 3);
        expect(combined.mutatesInventory, isTrue);
        expect(combined.destructive, isFalse);

        final hindi = parseAppBrainIntent('शॉर्ट एक्सपायरी १२ दिन सेट करो');
        expect(hindi.action, AppBrainAction.setWarningPolicy);
        expect(hindi.warningPolicy?.shortDays, 12);
      },
    );

    test('ordinary expiry lookup/list language cannot mutate policy', () {
      expect(parseAppBrainIntent('short expiry').action, AppBrainAction.search);
      final medicineQuestion = parseAppBrainIntent(
        'Dolo expiry 10 days set karo',
      );
      expect(medicineQuestion.action, isNot(AppBrainAction.setWarningPolicy));
    });

    test('policy changes obey the deterministic write firewall', () {
      for (final command in [
        'short expiry warning 10 days set mat karo',
        'tomorrow short expiry warning 10 days set karo',
        'Dolo delete karo and short expiry warning 10 days set karo',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
      }
    });

    test('ambiguous or unitless warning mutations fail closed', () {
      expect(
        () => parseWarningPolicyCommand(
          'short expiry warning 8 10 days set karo',
        ),
        throwsFormatException,
      );
      expect(
        () => parseWarningPolicyCommand('short expiry warning 10 set karo'),
        throwsFormatException,
      );
    });

    test('activity questions route to deterministic local audit history', () {
      for (final command in [
        'what changed today',
        'recent activity',
        'aaj kya change hua',
        'आज क्या बदला',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.activityBrief, reason: command);
        expect(intent.mutatesInventory, isFalse, reason: command);
        expect(intent.destructive, isFalse, reason: command);
      }
    });
  });

  group('reviewed warning policy transaction', () {
    test('policy update is validated, audited and undoable', () async {
      final controller = await makeController();
      addTearDown(controller.dispose);

      final review = controller.reviewWarningSettings(
        const WarningSettings(shortDays: 10, months: 3),
      );
      expect(review.baseRevision, 0);
      expect(review.changesSettings, isTrue);
      await controller.applyWarningSettings(review);

      expect(controller.settings.shortDays, 10);
      expect(controller.settings.months, 3);
      expect(controller.snapshot.events.first['label'], contains('10 days'));
      expect(controller.snapshot.events.first['label'], contains('3 months'));

      await controller.undo();
      expect(controller.settings.shortDays, 8);
      expect(controller.settings.months, 2);
    });

    test(
      'a stale policy review cannot overwrite newer inventory state',
      () async {
        final controller = await makeController();
        addTearDown(controller.dispose);
        final review = controller.reviewWarningSettings(
          const WarningSettings(shortDays: 10, months: 3),
        );

        await controller.save(
          Medicine.fromJson({
            'id': 'stock-a',
            'name': 'Dolo',
            'strength': '650 mg',
            'form': 'Tablet',
            'quantity': 10,
            'expiry': '2027-12',
            'revision': 1,
          }),
          expectedRevision: 0,
        );

        await expectLater(
          controller.applyWarningSettings(review),
          throwsStateError,
        );
        expect(controller.settings.shortDays, 8);
        expect(controller.settings.months, 2);
      },
    );

    test('invalid cross-window policy is rejected before review', () async {
      final controller = await makeController();
      addTearDown(controller.dispose);
      const patch = WarningPolicyPatch(shortDays: 60, months: 1);
      expect(() => patch.apply(controller.settings), throwsFormatException);
    });
  });
}
