import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/inventory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris App Brain', () {
    test('routes explicit remove intent with medicine target', () {
      final intent = parseAppBrainIntent('Dolo 650 delete karo');
      expect(intent.action, AppBrainAction.removeMedicine);
      expect(intent.query, 'Dolo 650');
      expect(intent.confidence, greaterThanOrEqualTo(.98));
    });

    test('explicit mutation wins over expiry category words', () {
      final intent = parseAppBrainIntent('expired Dolo 650 delete karo');
      expect(intent.action, AppBrainAction.removeMedicine);
      expect(intent.query, contains('Dolo 650'));
    });

    test('routes Hindi removal without an AI model', () {
      final intent = parseAppBrainIntent('Crocin 500 को हटा दो');
      expect(intent.action, AppBrainAction.removeMedicine);
      expect(intent.query, 'Crocin 500');
    });

    test('opens sold list without confusing it with mark sold', () {
      final intent = parseAppBrainIntent('sold medicines dikhao');
      expect(intent.action, AppBrainAction.search);
      expect(intent.scope, SearchScope.sold);
      expect(intent.query, isEmpty);
    });

    test('routes mark-sold target separately from sold list', () {
      final intent = parseAppBrainIntent('Dolo 650 stock khatam');
      expect(intent.action, AppBrainAction.markSold);
      expect(intent.query, 'Dolo 650');
    });

    test('routes expired list', () {
      final intent = parseAppBrainIntent('expired medicines dikhao');
      expect(intent.action, AppBrainAction.search);
      expect(intent.scope, SearchScope.expired);
    });

    test('routes inventory summary locally', () {
      final intent = parseAppBrainIntent('stock kitna hai');
      expect(intent.action, AppBrainAction.inventorySummary);
    });

    test('routes stock navigation', () {
      final intent = parseAppBrainIntent('medicine database kholo');
      expect(intent.action, AppBrainAction.navigate);
      expect(intent.section, AppSection.stock);
    });

    test('routes undo through dedicated safety action', () {
      final intent = parseAppBrainIntent('pichla change wapas karo');
      expect(intent.action, AppBrainAction.undoLast);
    });

    test('leaves complex reasoning to the existing AI pipeline', () {
      final intent = parseAppBrainIntent(
        'Which stock pattern should I review before next month?',
      );
      expect(intent.action, AppBrainAction.unknown);
    });
  });
}
