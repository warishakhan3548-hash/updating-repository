import 'package:aaris_pharmacy/domain/medicine.dart';
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
    expect(
      overview.ranked.first.demandShare(overview.totalUnitsSold),
      closeTo(2 / 3, 0.0001),
    );
  });

  test('direct SOLD immediately contributes entered amount and sold quantity', () {
    final sold = Medicine(
      id: 'p1',
      name: 'Paracetamol',
      quantity: 0,
      unitPricePaise: 2000,
      sold: true,
      soldAt: DateTime(2026, 9, 8, 12).toIso8601String(),
      soldQuantity: 25,
      soldUnitPricePaise: 2000,
    );

    final overview = SalesOverview(const [], medicines: [sold]);

    expect(overview.salesValuePaise, 2000);
    expect(overview.totalUnitsSold, 25);
    expect(overview.recordedSales, 1);
    expect(overview.ranked.single.name, 'Paracetamol');
    expect(overview.ranked.single.unitsSold, 25);
  });

  test('recorded sold-out sale is not counted twice by SOLD fallback', () {
    final time = DateTime(2026, 9, 8, 12);
    final sale = SaleEvent(
      id: 'sale-final',
      stockId: 'p1',
      medicineName: 'Paracetamol',
      quantity: 25,
      occurredAt: time,
      totalAmountPaise: 2000,
    );
    final sold = Medicine(
      id: 'p1',
      name: 'Paracetamol',
      quantity: 0,
      unitPricePaise: 2000,
      sold: true,
      soldAt: time.toIso8601String(),
      soldQuantity: 25,
      soldUnitPricePaise: 2000,
    );

    final overview = SalesOverview([sale], medicines: [sold]);

    expect(overview.salesValuePaise, 2000);
    expect(overview.totalUnitsSold, 25);
    expect(overview.recordedSales, 1);
  });

  test('direct SOLD remains in analytics after later restock', () {
    final beforeSold = Medicine(
      id: 'p1',
      name: 'Paracetamol',
      quantity: 25,
      unitPricePaise: 2000,
    );
    final restocked = Medicine(
      id: 'p1',
      name: 'Paracetamol',
      quantity: 10,
      unitPricePaise: 2200,
    );
    final event = <String, dynamic>{
      'soldValue': 50000,
      'unknownSold': 0,
      'salesBefore': <String, dynamic>{},
      'before': <String, dynamic>{'p1': beforeSold.toJson()},
    };

    final overview = SalesOverview(
      const [],
      medicines: [restocked],
      events: [event],
    );

    expect(overview.salesValuePaise, 2000);
    expect(overview.totalUnitsSold, 25);
    expect(overview.ranked.single.name, 'Paracetamol');
  });
}
