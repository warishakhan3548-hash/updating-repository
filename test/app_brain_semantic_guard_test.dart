import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain semantic guard', () {
    test('negated add-medicine intent never opens a write-like workflow', () {
      final intent = parseAppBrainIntent('do not add medicine Dolo 650');
      expect(intent.action, AppBrainAction.search);
      expect(intent.query, 'Dolo 650');
      expect(intent.mutatesInventory, isFalse);
      expect(intent.destructive, isFalse);
    });

    test('explanatory mutation wording stays read-only', () {
      for (final entry in <String, String>{
        'why delete Dolo 650': 'Dolo 650',
        'Dolo 650 ko delete kyun kare': 'Dolo 650',
        'what does remove Crocin 500 mean': 'Crocin 500',
      }.entries) {
        final intent = parseAppBrainIntent(entry.key);
        expect(intent.action, AppBrainAction.search, reason: entry.key);
        expect(intent.query, entry.value, reason: entry.key);
        expect(intent.mutatesInventory, isFalse, reason: entry.key);
        expect(intent.destructive, isFalse, reason: entry.key);
      }
    });

    test('deferred mutation wording fails closed', () {
      for (final command in <String>[
        'tomorrow delete Dolo 650',
        'Dolo 650 later remove karo',
        'Crocin 500 delete after stock check',
        'kal Dolo 650 delete karo',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.unknown, reason: command);
        expect(intent.mutatesInventory, isFalse, reason: command);
        expect(intent.confidence, 1, reason: command);
      }
    });

    test('incomplete stock correction plus another write cannot partially run', () {
      for (final command in <String>[
        'Dolo 650 quantity set karo aur delete karo',
        'add medicine Dolo 650 aur remove Crocin 500',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.unknown, reason: command);
        expect(intent.mutatesInventory, isFalse, reason: command);
        expect(intent.confidence, 1, reason: command);
      }
    });

    test('negated physical relocation is converted to a read-only lookup', () {
      final intent = parseAppBrainIntent('Dolo 650 location hata do mat karo');
      expect(intent.action, AppBrainAction.search);
      expect(intent.query, 'Dolo 650');
      expect(intent.mutatesInventory, isFalse);
    });

    test('oversized natural-language input fails closed before regex planning', () {
      final input = '${List<String>.filled(260, 'Dolo').join(' ')} delete';
      expect(input.length, greaterThan(1000));
      final intent = parseAppBrainIntent(input);
      expect(intent.action, AppBrainAction.unknown);
      expect(intent.mutatesInventory, isFalse);
    });
  });
}
