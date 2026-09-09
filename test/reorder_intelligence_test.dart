import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(
  String id, {
  int? quantity = 10,
  String expiry = '2026-12-31',
  bool sold = false,
  int? soldQuantity,
}) => Medicine.fromJson({
  'id': id,
  'name': 'Paracetamol',
  'strength': '500mg',
  'form': 'Tablet',
  'quantity': quantity,
  'expiry': expiry,
  'sold': sold,
  if (sold) 'soldAt': '2026-09-08T12:00:00',
  if (soldQuantity != null) 'soldQuantity': soldQuantity,
});

SaleEvent _sale(String id, int quantity, DateTime date) => SaleEvent(
  id: id,
  stockId: 'p1',
  medicineName: 'Paracetamol',
  strength: '500mg',
  form: 'Tablet',
  quantity: quantity,
  occurredAt: date,
);

void main() {
  final today = DateTime(2026, 9, 9);
  final range = TrackingRange.lastDays(today, 30);

  test('known zero stock is urgent even without a legacy SOLD marker', () {
    final stats = TrackingStats(
      medicines: [_stock('p1', quantity: 0)],
      sales: const [],
      range: range,
      today: today,
    );

    final suggestion = stats.reorder.single;
    expect(suggestion.priority, ReorderPriority.urgent);
    expect(suggestion.reason, 'Out of stock');
    expect(suggestion.suggestedQuantity, greaterThan(0));
    expect(suggestion.reviewRequired, isTrue);
  });

  test('repeated recorded sales raise reorder quantity confidence', () {
    final stats = TrackingStats(
      medicines: [_stock('p1', quantity: 2)],
      sales: [
        _sale('s1', 8, DateTime(2026, 9, 2)),
        _sale('s2', 8, DateTime(2026, 9, 5)),
        _sale('s3', 8, DateTime(2026, 9, 8)),
      ],
      range: range,
      today: today,
    );

    final suggestion = stats.reorder.single;
    expect(suggestion.priority, ReorderPriority.soon);
    expect(suggestion.confidence, greaterThanOrEqualTo(.9));
    expect(suggestion.reviewRequired, isFalse);
    expect(suggestion.coverageDays, isNotNull);
  });

  test('all sellable units expiring inside lead window trigger replacement pressure', () {
    final stats = TrackingStats(
      medicines: [_stock('p1', quantity: 12, expiry: '2026-09-13')],
      sales: [
        _sale('s1', 5, DateTime(2026, 9, 5)),
        _sale('s2', 5, DateTime(2026, 9, 7)),
        _sale('s3', 5, DateTime(2026, 9, 8)),
      ],
      range: range,
      today: today,
    );

    final suggestion = stats.reorder.single;
    expect(suggestion.reason, contains('expires within'));
    expect(suggestion.expiringWithinLeadUnits, 12);
    expect(suggestion.suggestedQuantity, greaterThan(0));
  });

  test('unknown quantity never becomes a fabricated reorder amount', () {
    final stats = TrackingStats(
      medicines: [_stock('p1', quantity: null)],
      sales: [
        _sale('s1', 20, DateTime(2026, 9, 8)),
      ],
      range: range,
      today: today,
    );

    expect(stats.reorder, isEmpty);
    expect(stats.movements.values.single.currentQuantity, isNull);
  });
}
