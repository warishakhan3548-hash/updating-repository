import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/brain_clarification.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(
  String id, {
  String batch = '',
  String barcode = '',
  String block = '',
  String row = '',
  String vertical = '',
  String location = '',
  int revision = 1,
}) => Medicine(
  id: id,
  name: 'Dolo',
  strength: '650 mg',
  form: 'Tablet',
  batchNumber: batch,
  barcode: barcode,
  block: block,
  row: row,
  vertical: vertical,
  location: location,
  quantity: 10,
  revision: revision,
);

PendingBrainChoice pending(List<Medicine> medicines, {DateTime? createdAt}) =>
    PendingBrainChoice(
      intent: const AppBrainIntent(action: AppBrainAction.removeMedicine),
      candidates: medicines,
      createdAt: createdAt ?? DateTime(2026, 9, 10, 9),
    );

void main() {
  group('Aaris Brain revision-bound clarification', () {
    test('resolves visible ordinals in English Hinglish Hindi and Devanagari digits', () {
      final a = stock('a', batch: 'A11');
      final b = stock('b', batch: 'B22');
      final choice = pending([a, b]);
      final records = {'a': a, 'b': b};
      final now = DateTime(2026, 9, 10, 9, 1);

      for (final words in [
        'second one',
        'option 2',
        'dusri wali',
        'दूसरी वाली',
        '२',
      ]) {
        final result = choice.resolve(words, records: records, now: now);
        expect(result.kind, BrainChoiceResolutionKind.resolved, reason: words);
        expect(result.stockId, 'b', reason: words);
      }
    });

    test('exact batch barcode and physical location labels resolve without fuzzy guessing', () {
      final a = stock(
        'a',
        batch: 'A11',
        barcode: '111111',
        block: 'B1',
        row: 'R1',
      );
      final b = stock(
        'b',
        batch: 'B22',
        barcode: '222222',
        block: 'B2',
        row: 'R2',
        vertical: 'V2',
        location: 'Fridge 2',
      );
      final choice = pending([a, b]);
      final records = {'a': a, 'b': b};
      final now = DateTime(2026, 9, 10, 9, 1);

      for (final entry in <String, String>{
        'batch B22 wali': 'b',
        'barcode 111111': 'a',
        'block B2': 'b',
        'row R1': 'a',
        'vertical V2': 'b',
        'location Fridge 2': 'b',
      }.entries) {
        final result = choice.resolve(entry.key, records: records, now: now);
        expect(
          result.kind,
          BrainChoiceResolutionKind.resolved,
          reason: entry.key,
        );
        expect(result.stockId, entry.value, reason: entry.key);
      }
    });

    test('a shared exact discriminator remains ambiguous', () {
      final a = stock('a', batch: 'A11', row: 'R1');
      final b = stock('b', batch: 'B22', row: 'R1');
      final result = pending([a, b]).resolve(
        'row R1',
        records: {'a': a, 'b': b},
        now: DateTime(2026, 9, 10, 9, 1),
      );
      expect(result.kind, BrainChoiceResolutionKind.ambiguous);
      expect(result.stockId, isNull);
    });

    test('loose medicine wording never becomes a destructive target', () {
      final a = stock('a', batch: 'A11');
      final b = stock('b', batch: 'B22');
      final result = pending([a, b]).resolve(
        'Dolo wali medicine',
        records: {'a': a, 'b': b},
        now: DateTime(2026, 9, 10, 9, 1),
      );
      expect(result.kind, BrainChoiceResolutionKind.noMatch);
      expect(result.stockId, isNull);
    });

    test(
      'any displayed row revision change invalidates the whole option map',
      () {
        final a = stock('a', batch: 'A11');
        final b = stock('b', batch: 'B22');
        final result = pending([a, b]).resolve(
          'second one',
          records: {
            'a': a,
            'b': stock('b', batch: 'B22', revision: 2),
          },
          now: DateTime(2026, 9, 10, 9, 1),
        );
        expect(result.kind, BrainChoiceResolutionKind.stale);
      },
    );

    test('clarification expires and cancellation never selects stock', () {
      final a = stock('a');
      final b = stock('b');
      final records = {'a': a, 'b': b};
      final stale = pending([a, b]).resolve(
        'first one',
        records: records,
        now: DateTime(2026, 9, 10, 9, 6),
      );
      expect(stale.kind, BrainChoiceResolutionKind.stale);

      for (final words in ['cancel', 'rehne do', 'छोड़ दो']) {
        final result = pending([a, b])
            .resolve(words, records: records, now: DateTime(2026, 9, 10, 9, 1));
        expect(result.kind, BrainChoiceResolutionKind.cancelled, reason: words);
        expect(result.stockId, isNull, reason: words);
      }
    });

    test('backward clock movement invalidates the pending option map', () {
      final a = stock('a');
      final b = stock('b');
      final result = pending([a, b]).resolve(
        'first one',
        records: {'a': a, 'b': b},
        now: DateTime(2026, 9, 10, 8, 59),
      );
      expect(result.kind, BrainChoiceResolutionKind.stale);
    });
  });
}
