import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _medicine(
  String id, {
  bool sold = false,
  int? quantity = 0,
  int? unitPricePaise,
  String? soldAt,
  int? soldQuantity,
  int? soldUnitPricePaise,
}) => Medicine.fromJson({
  'id': id,
  'name': 'AuditMed',
  'strength': '10mg',
  'form': 'Tablet',
  'expiry': '2027-12',
  'quantity': sold ? 0 : quantity,
  'unitPricePaise': unitPricePaise,
  'sold': sold,
  'soldAt': soldAt,
  'soldQuantity': soldQuantity,
  'soldUnitPricePaise': soldUnitPricePaise,
});

void main() {
  group('reorder evidence integrity', () {
    final today = DateTime(2026, 9, 10);
    final range = TrackingRange.lastDays(today, 30);

    test('stale SOLD fields on active stock cannot inflate reorder evidence', () {
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
    });

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
  });
}
