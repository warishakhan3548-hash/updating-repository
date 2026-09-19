import 'package:flutter_test/flutter_test.dart';

import '../lib/services/offline_recognition_memory_service.dart';

Map<String, Object?> row(String identity, String alias, {int support = 1}) => {
  'identity_key': identity, 'alias': alias, 'normalized_alias': alias,
  'support': support, 'last_confirmed': 1000,
};

void main() {
  test('Top-K cannot make an alias unique by hiding its competing identity', () {
    final groups = completeRecognitionAliasGroups(
      [row('medicine-a', 'damaged-name', support: 1000000)],
      {'damaged-name': 2},
    );
    expect(groups, isEmpty);
  });
  test('an unrelated complete group survives another alias being truncated', () {
    final groups = completeRecognitionAliasGroups([
      row('medicine-a', 'ambiguous'), row('medicine-b', 'complete'),
    ], {'ambiguous': 4, 'complete': 1});
    expect(groups.keys, ['complete']);
  });
  test('all candidates remain available for strength/form arbitration', () {
    final groups = completeRecognitionAliasGroups([
      row('125-suspension', 'paraceta'), row('500-tablet', 'paraceta'),
    ], {'paraceta': 2});
    expect(groups['paraceta']!.length, 2);
  });
  test('corrupt or duplicated rows cannot count as independent confirmations', () {
    final valid = row('medicine-a', 'damaged');
    expect(completeRecognitionAliasGroups([
      valid, {...row('medicine-b', 'damaged'), 'support': double.nan},
    ], {'damaged': 2}), isEmpty);
    expect(completeRecognitionAliasGroups([valid, valid],
      {'damaged': 2}), isEmpty);
    expect(completeRecognitionAliasGroups([valid], {}), isEmpty);
  });
}
