import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _medicine(
  String id, {
  String name = 'AuditMed',
  String salt = '',
  String strength = '10mg',
  String form = 'Tablet',
  bool sold = false,
  int? quantity = 0,
  int? unitPricePaise,
  String? soldAt,
  int? soldQuantity,
  int? soldUnitPricePaise,
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'salt': salt,
  'strength': strength,
  'form': form,
  'expiry': '2027-12',
  'quantity': sold ? 0 : quantity,
  'unitPricePaise': unitPricePaise,
  'sold': sold,
  'soldAt': soldAt,
  'soldQuantity': soldQuantity,
  'soldUnitPricePaise': soldUnitPricePaise,
});

SaleEvent _sale({
  required String id,
  required String stockId,
  required String name,
  String salt = '',
  String strength = '10mg',
  String form = 'Tablet',
  int quantity = 30,
}) => SaleEvent(
  id: id,
  stockId: stockId,
  medicineName: name,
  salt: salt,
  strength: strength,
  form: form,
  quantity: quantity,
  occurredAt: DateTime(2026, 9, 9, 10),
);

void main() {
  group('reorder evidence integrity', () {
    final today = DateTime(2026, 9, 10);
    final range = TrackingRange.lastDays(today, 30);

    test(
      'stale SOLD fields on active stock cannot inflate reorder evidence',
      () {
        final stats = TrackingStats(
          medicines: [
            _medicine(
              'active',
              quantity: 0,
              soldAt: '2026-08-01T10:00:00.000',
              soldQuantity: 5000,
              soldUnitPricePaise: 99999,
            ),
          ],
          sales: const [],
          range: range,
          today: today,
        );

        expect(stats.reorder, hasLength(1));
        expect(stats.reorder.single.suggestedQuantity, 10);
        expect(stats.reorder.single.unitPricePaise, isNull);
        expect(stats.reorder.single.reviewRequired, isTrue);
      },
    );

    test('genuine SOLD history remains valid reorder evidence', () {
      final stats = TrackingStats(
        medicines: [
          _medicine(
            'sold',
            sold: true,
            soldAt: '2026-09-01T10:00:00.000',
            soldQuantity: 40,
            soldUnitPricePaise: 725,
          ),
        ],
        sales: const [],
        range: range,
        today: today,
      );

      expect(stats.reorder, hasLength(1));
      expect(stats.reorder.single.suggestedQuantity, 40);
      expect(stats.reorder.single.unitPricePaise, 725);
    });

    test(
      'identity edit cannot relabel historical demand into the new medicine',
      () {
        final current = _medicine('stock', name: 'NewName', quantity: 0);
        final historical = _sale(
          id: 'sale-old',
          stockId: current.id,
          name: 'OldName',
          quantity: 30,
        );

        final stats = TrackingStats(
          medicines: [current],
          sales: [historical],
          range: range,
          today: today,
        );

        final oldKey = historical.productKey;
        final newKey = current.identity;
        expect(oldKey, isNot(newKey));
        expect(stats.movements[oldKey]?.unitsSold, 30);
        expect(stats.movements[newKey]?.unitsSold, 0);
        expect(stats.reorder, hasLength(1));
        expect(stats.reorder.single.productKey, newKey);
        expect(stats.reorder.single.unitsSold, 0);
        expect(stats.reorder.single.unitsPerDay, 0);
        expect(stats.reorder.single.suggestedQuantity, 10);
        expect(stats.reorder.single.reviewRequired, isTrue);
      },
    );

    test(
      'conflicting known salt evidence cannot drive automated reorder velocity',
      () {
        final current = _medicine(
          'stock',
          name: 'SameName',
          salt: 'Current Salt',
          quantity: 0,
        );
        final historical = _sale(
          id: 'sale-conflict',
          stockId: current.id,
          name: current.name,
          salt: 'Different Salt',
          quantity: 90,
        );

        final stats = TrackingStats(
          medicines: [current],
          sales: [historical],
          range: range,
          today: today,
        );

        expect(stats.movements[current.identity]?.unitsSold, 90);
        expect(stats.reorder, hasLength(1));
        final suggestion = stats.reorder.single;
        expect(suggestion.unitsSold, 0);
        expect(suggestion.unitsPerDay, 0);
        expect(suggestion.suggestedQuantity, 10);
        expect(suggestion.confidence, .35);
        expect(suggestion.reviewRequired, isTrue);
        expect(suggestion.reason, contains('sales identity needs review'));
      },
    );

    test('matching immutable sale identity still powers reorder velocity', () {
      final current = _medicine(
        'stock',
        name: 'SameName',
        salt: 'Same Salt',
        quantity: 0,
      );
      final historical = _sale(
        id: 'sale-valid',
        stockId: current.id,
        name: current.name,
        salt: current.salt,
        quantity: 30,
      );

      final stats = TrackingStats(
        medicines: [current],
        sales: [historical],
        range: range,
        today: today,
      );

      expect(stats.reorder, hasLength(1));
      final suggestion = stats.reorder.single;
      expect(suggestion.unitsSold, 30);
      expect(suggestion.unitsPerDay, 1);
      expect(suggestion.suggestedQuantity, 30);
      expect(suggestion.confidence, .82);
      expect(suggestion.reviewRequired, isFalse);
    });
  });
}
