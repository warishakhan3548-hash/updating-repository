import 'package:aaris_pharmacy/domain/sales_overview.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sales value uses recorded totals then saved price fallback', () {
    final overview = SalesOverview([
      SaleEvent(
        id: 's1',
        stockId: 'p1',
        medicineName: 'Paracetamol',
        quantity: 2,
        occurredAt: DateTime(2026, 9, 8),
        totalAmountPaise: 5000,
        savedUnitPricePaise: 9999,
      ),
      SaleEvent(
        id: 's2',
        stockId: 'c1',
        medicineName: 'Cefixime',
        quantity: 3,
        occurredAt: DateTime(2026, 9, 8),
        savedUnitPricePaise: 1000,
      ),
      SaleEvent(
        id: 's3',
        stockId: 'u1',
        medicineName: 'Unknown value medicine',
        quantity: 1,
        occurredAt: DateTime(2026, 9, 8),
      ),
    ]);

    expect(overview.salesValuePaise, 8000);
    expect(overview.unknownValueSales, 1);
    expect(overview.totalUnitsSold, 6);
  });

  test('tracker groups strengths by medicine name and ranks by sold units', () {
    final overview = SalesOverview([
      SaleEvent(
        id: 'p500',
        stockId: 'p500',
        medicineName: 'Paracetamol',
        strength: '500mg',
        quantity: 4,
        occurredAt: DateTime(2026, 9, 8),
      ),
      SaleEvent(
        id: 'p650',
        stockId: 'p650',
        medicineName: 'PARACETAMOL',
        strength: '650mg',
        quantity: 6,
        occurredAt: DateTime(2026, 9, 8),
      ),
      SaleEvent(
        id: 'c',
        stockId: 'c',
        medicineName: 'Cefixime',
        quantity: 5,
        occurredAt: DateTime(2026, 9, 8),
      ),
    ]);

    expect(overview.ranked.length, 2);
    expect(overview.ranked.first.name, 'Paracetamol');
    expect(overview.ranked.first.unitsSold, 10);
    expect(overview.ranked.first.demandShare(overview.totalUnitsSold), closeTo(2 / 3, 0.0001));
  });
}
