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
      expect(intent.destructive, isTrue);
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

    test('query cleanup never removes filler letters inside a medicine name', () {
      final intent = parseAppBrainIntent('Koflet delete karo');
      expect(intent.action, AppBrainAction.removeMedicine);
      expect(intent.query, 'Koflet');
    });

    test('blocks bulk destructive natural-language commands', () {
      final intent = parseAppBrainIntent('sab medicines delete karo');
      expect(intent.action, AppBrainAction.bulkRemoveBlocked);
      expect(intent.confidence, 1);
      expect(intent.destructive, isTrue);
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

    test('routes proactive attention brief locally', () {
      final intent = parseAppBrainIntent('aaj kya karna hai');
      expect(intent.action, AppBrainAction.attentionBrief);
      expect(intent.confidence, greaterThanOrEqualTo(.98));
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

    test('batch identifier can be searched without saying search', () {
      final intent = parseAppBrainIntent('batch AB12');
      expect(intent.action, AppBrainAction.search);
      expect(intent.query, 'AB12');
      expect(intent.confidence, greaterThanOrEqualTo(.95));
    });

    test('short medicine text becomes a fast local lookup', () {
      final intent = parseAppBrainIntent('Dolo 650');
      expect(intent.action, AppBrainAction.search);
      expect(intent.query, 'Dolo 650');
    });

    test('recognizes safe conversational follow-up references', () {
      expect(isAppBrainContextReference('isko'), isTrue);
      expect(isAppBrainContextReference('same one'), isTrue);
      expect(isAppBrainContextReference('इसको'), isTrue);
      expect(isAppBrainContextReference('Dolo 650'), isFalse);
    });

    test('leaves complex reasoning to the existing AI pipeline', () {
      final intent = parseAppBrainIntent(
        'Which stock pattern should I review before next month?',
      );
      expect(intent.action, AppBrainAction.unknown);
    });

    test('medicine advice remains outside deterministic app commands', () {
      final intent = parseAppBrainIntent('Dolo 650 dose after food');
      expect(intent.action, AppBrainAction.unknown);
    });
  });
}
