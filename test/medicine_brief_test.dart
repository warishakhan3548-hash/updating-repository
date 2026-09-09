import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_brief.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(
  String id, {
  int? quantity = 10,
  DateTime? expiry,
  bool expiryMonthOnly = false,
  DateTime? mfg,
  String batch = '',
  String location = '',
  String salt = 'Paracetamol',
  bool sold = false,
  bool archived = false,
}) => Medicine(
  id: id,
  name: 'Dolo',
  strength: '650mg',
  form: 'Tablet',
  quantity: sold ? 0 : quantity,
  expiry: expiry,
  expiryMonthOnly: expiryMonthOnly,
  mfg: mfg,
  batchNumber: batch,
  location: location,
  salt: salt,
  sold: sold,
  archived: archived,
);

void main() {
  final today = DateTime.utc(2026, 9, 10);

  group('MedicineOperationalBrief', () {
    test('aggregates only current FEFO-eligible stock and preserves unknowns', () {
      final anchor = stock(
        'a',
        quantity: 10,
        expiry: DateTime.utc(2026, 10, 1),
        batch: 'A1',
        location: 'Shelf 1',
      );
      final brief = MedicineOperationalBrief.build(
        records: [
          anchor,
          stock('unknown', quantity: null, batch: 'B1'),
          stock(
            'expired',
            quantity: 5,
            expiry: DateTime.utc(2026, 9, 9),
            batch: 'OLD',
          ),
          stock(
            'future',
            quantity: 7,
            mfg: DateTime.utc(2026, 9, 11),
            expiry: DateTime.utc(2027, 1, 1),
          ),
          stock(
            'zero',
            quantity: 0,
            expiry: DateTime.utc(2027, 1, 1),
          ),
          stock('sold', sold: true, expiry: DateTime.utc(2027, 1, 1)),
          stock(
            'archived',
            archived: true,
            expiry: DateTime.utc(2027, 1, 1),
          ),
        ],
        anchor: anchor,
        today: today,
      );

      expect(brief.activeBatchCount, 5);
      expect(brief.fefoEligibleBatchCount, 2);
      expect(brief.knownUsableUnits, 10);
      expect(brief.unknownQuantityBatchCount, 1);
      expect(brief.exactUsableQuantityKnown, isFalse);
      expect(brief.expiredBatchCount, 1);
      expect(brief.futureManufactureBatchCount, 1);
      expect(brief.zeroQuantityBatchCount, 1);
      expect(brief.unknownExpiryBatchCount, 1);
      expect(brief.unlocatedBatchCount, 1);
      expect(brief.nextFefo?.id, 'a');
      expect(brief.locations, ['Shelf 1']);

      final answer = brief.describe(MedicineBriefFocus.stock);
      expect(answer, contains('10 known units plus 1 current batch'));
      expect(answer, contains('will not guess the exact total'));
      expect(answer, contains('1 expired active row is excluded'));
      expect(answer, contains('1 future-MFG row is excluded'));
      expect(answer, contains('1 active row has 0 units'));
    });

    test('FEFO never skips an earlier-priority batch with unknown quantity', () {
      final unknownEarlier = stock(
        'early',
        quantity: null,
        expiry: DateTime.utc(2026, 9, 20),
        batch: 'EARLY',
        location: 'Rack A',
      );
      final knownLater = stock(
        'later',
        quantity: 20,
        expiry: DateTime.utc(2026, 10, 20),
        batch: 'LATER',
        location: 'Rack B',
      );
      final brief = MedicineOperationalBrief.build(
        records: [unknownEarlier, knownLater],
        anchor: knownLater,
        today: today,
      );

      expect(brief.nextFefo?.id, 'early');
      final answer = brief.describe(MedicineBriefFocus.fefo);
      expect(answer, contains('Batch EARLY'));
      expect(answer, contains('quantity unknown'));
      expect(answer, contains('will not skip an earlier-priority unknown batch'));
    });

    test('formats printed month-only expiry without inventing a day', () {
      final anchor = stock(
        'month',
        expiry: DateTime.utc(2026, 12, 31),
        expiryMonthOnly: true,
        batch: 'M12',
      );
      final brief = MedicineOperationalBrief.build(
        records: [anchor],
        anchor: anchor,
        today: today,
      );

      final answer = brief.describe(MedicineBriefFocus.expiry);
      expect(answer, contains('2026-12'));
      expect(answer, isNot(contains('2026-12-31')));
    });

    test('fails closed when product-level salt facts conflict', () {
      final first = stock(
        'salt-a',
        expiry: DateTime.utc(2027, 1, 1),
        salt: 'Paracetamol',
      );
      final second = stock(
        'salt-b',
        expiry: DateTime.utc(2027, 2, 1),
        salt: 'Ibuprofen',
      );
      final brief = MedicineOperationalBrief.build(
        records: [first, second],
        anchor: first,
        today: today,
      );

      expect(brief.conflictingSaltFacts, isTrue);
      for (final focus in MedicineBriefFocus.values) {
        expect(brief.describe(focus), contains('needs identity review'));
        expect(brief.describe(focus), contains('will not combine'));
      }
    });

    test('location answer never invents missing storage locations', () {
      final first = stock(
        'loc-a',
        expiry: DateTime.utc(2027, 1, 1),
        location: 'Drawer 3',
      );
      final second = stock(
        'loc-b',
        expiry: DateTime.utc(2027, 2, 1),
        location: '',
      );
      final brief = MedicineOperationalBrief.build(
        records: [first, second],
        anchor: first,
        today: today,
      );

      final answer = brief.describe(MedicineBriefFocus.location);
      expect(answer, contains('Drawer 3'));
      expect(answer, contains('1 current batch has no recorded location'));
    });
  });
}
