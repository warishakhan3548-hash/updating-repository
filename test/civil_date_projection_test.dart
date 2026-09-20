import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/home_projection.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/search.dart';

void main() {
  test('civil date normalization stays invisible to read-model dependencies', () {
    final original = Medicine(
      id: 'civil-date-projection',
      name: 'Civil Date Medicine',
      mfg: DateTime(2026, 1, 15),
      expiry: DateTime(2027, 1, 15),
      quantity: 10,
    );
    final persistedShape = original.patch({'quantity': 9});

    expect(
      sameCivilDate(original.mfg, persistedShape.mfg),
      isTrue,
      reason: 'MFG is a printed calendar fact, not an instant in time.',
    );
    expect(
      sameCivilDate(original.expiry, persistedShape.expiry),
      isTrue,
      reason: 'EXP is a printed calendar fact, not an instant in time.',
    );
    expect(
      sameSearchProjection(original, persistedShape),
      isTrue,
      reason:
          'A stock-only write must not rebuild the fuzzy search index because date serialization normalized its time basis.',
    );
    expect(
      sameHomeProjectionInput(original, persistedShape),
      isTrue,
      reason:
          'The Home projection must use the same authoritative civil-date semantics.',
    );
  });

  test('a real printed date edit still invalidates Home and search projections', () {
    final original = Medicine(
      id: 'civil-date-change',
      name: 'Civil Date Change',
      mfg: DateTime(2026, 1, 15),
      expiry: DateTime(2027, 1, 15),
      quantity: 10,
    );
    final changed = original.patch({'expiry': '2027-01-16'});

    expect(sameCivilDate(original.expiry, changed.expiry), isFalse);
    expect(sameSearchProjection(original, changed), isFalse);
    expect(sameHomeProjectionInput(original, changed), isFalse);
  });
}
