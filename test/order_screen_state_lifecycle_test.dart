import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/order_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reorder form state resets after suggestion lifecycle ends', (
    tester,
  ) async {
    final today = DateTime(2026, 9, 20, 10);
    final medicine = Medicine(
      id: 'order-cycle-stock',
      name: 'Order Cycle Medicine',
      strength: '500mg',
      form: 'Tablet',
      quantity: 2,
      expiry: DateTime(2027, 1, 1),
    );
    SaleEvent sale(String id, int daysAgo) => SaleEvent(
      id: id,
      stockId: medicine.id,
      medicineName: medicine.name,
      strength: medicine.strength,
      form: medicine.form,
      quantity: 8,
      occurredAt: today.subtract(Duration(days: daysAgo)),
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          records: <String, Medicine>{medicine.id: medicine},
          sales: <String, SaleEvent>{
            'order-cycle-sale-1': sale('order-cycle-sale-1', 2),
            'order-cycle-sale-2': sale('order-cycle-sale-2', 5),
            'order-cycle-sale-3': sale('order-cycle-sale-3', 8),
          },
        ),
      ),
      clock: () => today,
      backgroundSearch: false,
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: OrderScreen(
          controller: controller,
          range: TrackingRange.lastDays(today, 30),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    expect(find.byType(TextField), findsNWidgets(2));

    final quantity = find.byType(TextField).first;
    await tester.enterText(quantity, '77');
    expect(tester.widget<TextField>(quantity).controller?.text, '77');

    var live = controller.snapshot.records[medicine.id]!;
    await controller.save(
      live.patch(<String, dynamic>{'quantity': 1000}),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.byType(TextField), findsNothing);

    live = controller.snapshot.records[medicine.id]!;
    await controller.save(
      live.patch(<String, dynamic>{'quantity': 2}),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller?.text,
      isNot('77'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
