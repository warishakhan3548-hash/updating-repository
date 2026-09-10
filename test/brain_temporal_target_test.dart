import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain inventory-date versus schedule firewall', () {
    test('labelled EXP/MFG dates may identify a stock row', () {
      for (final command in [
        'remove Dolo 650 EXP 12/09/2026',
        'Dolo 650 expiry 2026-09-12 remove',
        'Dolo 650 MFG 01/09/2026 delete',
        'remove Dolo 650 MFD 12 Sep 2026',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.removeMedicine, reason: command);
        expect(intent.safetyReason, isNull, reason: command);
      }
    });

    test('unlabelled and schedule-shaped dates still fail closed', () {
      for (final command in [
        'remove Dolo on 12/09/2026',
        'remove Dolo 12/09/2026',
        'remove Dolo on expiry 12/09/2026',
        'Dolo delete Sep 12, 2026',
        'Dolo delete on 12 Sep 2026',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
        expect(
          intent.safetyReason,
          AppBrainSafetyReason.deferredMutation,
          reason: command,
        );
      }
    });

    test('clock and relative-time guards remain unchanged', () {
      for (final command in [
        'remove Dolo at 17:30',
        'remove Dolo at 5 pm',
        'Dolo 2 hours baad remove',
        'Dolo २ ghante baad remove',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
        expect(
          intent.safetyReason,
          AppBrainSafetyReason.deferredMutation,
          reason: command,
        );
      }
    });
  });
}
