import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine.dart';
import '../lib/domain/tracking.dart';
import '../lib/domain/work_queue.dart';

Medicine stock(
  String id, {
  String name = 'Paracetamol',
  String strength = '500mg',
  String expiry = '2027-12-31',
  int? quantity = 20,
  bool sold = false,
  bool archived = false,
  String location = 'Shelf A',
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'form': 'Tablet',
  'expiry': expiry,
  'quantity': sold ? 0 : quantity,
  'sold': sold,
  'archived': archived,
  'location': location,
});

void main() {
  final today = DateTime(2026, 9, 9);
  const settings = WarningSettings(shortDays: 8, months: 2);

  test('orders safety work before routine inventory cleanup', () {
    final queue = PharmacyWorkQueue.build(
      medicines: [
        stock('month', name: 'Month', expiry: '2026-10-20'),
        stock('short', name: 'Short', expiry: '2026-09-12'),
        stock('expired', name: 'Expired', expiry: '2026-09-08'),
        stock(
          'archived',
          name: 'Archived',
          expiry: '2020-01-01',
          archived: true,
        ),
      ],
      sales: const <SaleEvent>[],
      settings: settings,
      today: today,
    );

    expect(
      queue.tasks.map((task) => task.kind).toList(),
      [
        PharmacistTaskKind.expired,
        PharmacistTaskKind.shortExpiry,
        PharmacistTaskKind.monthExpiry,
      ],
    );
    expect(queue.criticalCount, 1);
    expect(queue.highCount, 1);
    expect(queue.safetyCount, 2);
  });

  test('zero quantity without SOLD is a high-priority stock inconsistency', () {
    final queue = PharmacyWorkQueue.build(
      medicines: [stock('zero', quantity: 0)],
      sales: const <SaleEvent>[],
      settings: settings,
      today: today,
    );

    expect(queue.tasks, hasLength(1));
    expect(queue.tasks.single.kind, PharmacistTaskKind.zeroQuantity);
    expect(queue.tasks.single.priority, PharmacistTaskPriority.high);
    expect(queue.stockCount, 1);
  });

  test('shows one strongest missing-fact task per stock entry', () {
    final queue = PharmacyWorkQueue.build(
      medicines: [
        stock(
          'unknown',
          expiry: '',
          quantity: null,
          location: '',
        ),
      ],
      sales: const <SaleEvent>[],
      settings: settings,
      today: today,
    );

    expect(queue.tasks, hasLength(1));
    expect(queue.tasks.single.kind, PharmacistTaskKind.missingExpiry);
    expect(queue.dataQualityCount, 1);
  });

  test('sales velocity creates deterministic low-stock reorder quantity', () {
    final queue = PharmacyWorkQueue.build(
      medicines: [stock('low', name: 'Dolo', quantity: 2)],
      sales: [
        SaleEvent(
          id: 'sale-1',
          stockId: 'low',
          medicineName: 'Dolo',
          strength: '500mg',
          form: 'Tablet',
          quantity: 30,
          occurredAt: DateTime(2026, 9, 9),
        ),
      ],
      settings: settings,
      today: today,
    );

    final reorder = queue.tasks.singleWhere(
      (task) => task.kind == PharmacistTaskKind.reorder,
    );
    expect(reorder.priority, PharmacistTaskPriority.routine);
    expect(reorder.suggestedQuantity, 28);
    expect(reorder.message, contains('1.0 units/day'));
  });

  test('strong stock inconsistency suppresses duplicate reorder task', () {
    final queue = PharmacyWorkQueue.build(
      medicines: [stock('zero', name: 'Cefixime', quantity: 0)],
      sales: [
        SaleEvent(
          id: 'sale-2',
          stockId: 'zero',
          medicineName: 'Cefixime',
          strength: '500mg',
          form: 'Tablet',
          quantity: 10,
          occurredAt: DateTime(2026, 9, 8),
        ),
      ],
      settings: settings,
      today: today,
    );

    expect(
      queue.tasks.where((task) => task.productKey == stock('x', name: 'Cefixime').identity),
      hasLength(1),
    );
    expect(queue.tasks.single.kind, PharmacistTaskKind.zeroQuantity);
  });

  test('rejects an unbounded reorder analysis window', () {
    expect(
      () => PharmacyWorkQueue.build(
        medicines: const <Medicine>[],
        sales: const <SaleEvent>[],
        settings: settings,
        today: today,
        reorderWindowDays: 3661,
      ),
      throwsFormatException,
    );
  });
}
