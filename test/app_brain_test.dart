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

    test(
      'query cleanup never removes filler letters inside a medicine name',
      () {
        final intent = parseAppBrainIntent('Koflet delete karo');
        expect(intent.action, AppBrainAction.removeMedicine);
        expect(intent.query, 'Koflet');
      },
    );

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

    test('targetless stock-finished wording is informational', () {
      final intent = parseAppBrainIntent('stock khatam');
      expect(intent.action, AppBrainAction.search);
      expect(intent.scope, SearchScope.sold);
      expect(intent.destructive, isFalse);
    });

    test('routes mark-sold target separately from sold list', () {
      final intent = parseAppBrainIntent('Dolo 650 stock khatam');
      expect(intent.action, AppBrainAction.markSold);
      expect(intent.query, 'Dolo 650');
      expect(intent.destructive, isTrue);
    });

    test('routes expired list', () {
      final intent = parseAppBrainIntent('expired medicines dikhao');
      expect(intent.action, AppBrainAction.search);
      expect(intent.scope, SearchScope.expired);
    });

    test('category expiry commands keep dashboard scope semantics', () {
      for (final entry in <String, SearchScope>{
        'short expiry': SearchScope.shortExpiry,
        'month expiry': SearchScope.monthExpiry,
      }.entries) {
        final intent = parseAppBrainIntent(entry.key);
        expect(intent.action, AppBrainAction.search, reason: entry.key);
        expect(intent.scope, entry.value, reason: entry.key);
        expect(intent.query, isEmpty, reason: entry.key);
      }
    });

    test('routes reorder review locally without treating it as AI advice', () {
      for (final command in [
        'order now',
        'reorder list',
        'low stock review',
        'kya order karna hai',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.reorderReview, reason: command);
        expect(intent.confidence, greaterThanOrEqualTo(.98), reason: command);
        expect(intent.destructive, isFalse, reason: command);
      }
    });

    test('routes targetless inventory summary locally', () {
      final intent = parseAppBrainIntent('stock kitna hai');
      expect(intent.action, AppBrainAction.inventorySummary);
    });

    test('targeted stock quantity question searches that medicine, not global totals', () {
      final intent = parseAppBrainIntent('Dolo 650 stock kitna hai');
      expect(intent.action, AppBrainAction.search);
      expect(intent.query, 'Dolo 650');
      expect(intent.scope, SearchScope.all);
      expect(intent.destructive, isFalse);
    });

    test('location question becomes an exact local stock lookup', () {
      final intent = parseAppBrainIntent('Dolo 650 kahan hai');
      expect(intent.action, AppBrainAction.search);
      expect(intent.query, 'Dolo 650');
      expect(intent.confidence, greaterThanOrEqualTo(.98));
    });

    test(
      'expiry question becomes a local stock lookup without medical inference',
      () {
        final intent = parseAppBrainIntent('Dolo 650 expiry kab hai');
        expect(intent.action, AppBrainAction.search);
        expect(intent.query, 'Dolo 650');
        expect(intent.destructive, isFalse);
      },
    );

    test(
      'FEFO question stays read-only and resolves through inventory search',
      () {
        final intent = parseAppBrainIntent('Dolo 650 pehle kaunsi batch');
        expect(intent.action, AppBrainAction.search);
        expect(intent.query, 'Dolo 650');
        expect(intent.confidence, greaterThanOrEqualTo(.99));
        expect(intent.destructive, isFalse);
      },
    );

    test(
      'read-only sales and movement language never becomes a sale mutation',
      () {
        for (final command in [
          'aaj ki bikri kitni',
          'sales report',
          'fast moving medicines',
          'slow moving stock',
        ]) {
          final intent = parseAppBrainIntent(command);
          expect(intent.action, AppBrainAction.navigate, reason: command);
          expect(intent.section, AppSection.calculator, reason: command);
          expect(intent.destructive, isFalse, reason: command);
        }
      },
    );

    test('explicit record-sale command still owns the write path', () {
      final intent = parseAppBrainIntent('Dolo 650 record sale');
      expect(intent.action, AppBrainAction.recordSale);
      expect(intent.query, 'Dolo 650');
      expect(intent.destructive, isTrue);
    });

    test(
      'explicit sale units are parsed without confusing medicine strength',
      () {
        final intent = parseAppBrainIntent('Dolo 650 12 units record sale');
        expect(intent.action, AppBrainAction.recordSale);
        expect(intent.query, 'Dolo 650');
        expect(intent.quantity, 12);

        final qtyIntent = parseAppBrainIntent('Dolo 650 record sale qty 7');
        expect(qtyIntent.query, 'Dolo 650');
        expect(qtyIntent.quantity, 7);

        final hindiDigits = parseAppBrainIntent('Dolo 650 ५ units record sale');
        expect(hindiDigits.query, 'Dolo 650');
        expect(hindiDigits.quantity, 5);

        final strengthOnly = parseAppBrainIntent('Dolo 650 record sale');
        expect(strengthOnly.query, 'Dolo 650');
        expect(strengthOnly.quantity, isNull);
      },
    );

    test('ambiguous multiple sale quantities never auto-plan a mutation', () {
      final intent = parseAppBrainIntent('Dolo 650 qty 5 6 units record sale');
      expect(intent.action, AppBrainAction.recordSale);
      expect(intent.quantity, isNull);
    });

    test(
      'phrase boundaries prevent medicine text from becoming a write command',
      () {
        final intent = parseAppBrainIntent('Wholesaler 10');
        expect(intent.action, AppBrainAction.search);
        expect(intent.query, 'Wholesaler 10');
        expect(intent.destructive, isFalse);
      },
    );

    test('data quality language opens the deterministic attention engine', () {
      for (final command in [
        'data quality check',
        'barcode conflict',
        'missing expiry',
        'future mfg',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.attentionBrief, reason: command);
        expect(intent.destructive, isFalse, reason: command);
      }
    });

    test('scanner language launches the reviewed scanner pipeline', () {
      for (final command in ['scanner kholo', 'scan medicine', 'स्कैन करो']) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.scanMedicine, reason: command);
        expect(intent.destructive, isFalse, reason: command);
        expect(intent.needsMedicineTarget, isFalse, reason: command);
      }
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
      for (final phrase in [
        'isko',
        'same one',
        'iska',
        'uski',
        'इसको',
        'इसका',
        'उसकी',
      ]) {
        expect(isAppBrainContextReference(phrase), isTrue, reason: phrase);
      }
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
