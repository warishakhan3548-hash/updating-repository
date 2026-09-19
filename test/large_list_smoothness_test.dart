import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/tracking.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/stats_screen.dart';

void main() {
  testWidgets('sold medicine tracker lazily renders a large demand ranking', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sales = <String, SaleEvent>{
      for (var index = 0; index < 240; index++)
        'sale-$index': SaleEvent(
          id: 'sale-$index',
          stockId: 'stock-$index',
          medicineName: 'Medicine $index',
          quantity: 240 - index,
          occurredAt: DateTime(2026, 9, 19, 12),
        ),
    };
    final controller = PharmacyController(
      MemoryInventoryStorage(InventorySnapshot(sales: sales)),
      clock: () => DateTime(2026, 9, 20),
      backgroundSearch: false,
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: StatsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Sold Medicine Tracker'),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Sold Medicine Tracker'));
    await tester.pumpAndSettle();

    expect(find.text('Medicine 0'), findsOneWidget);
    expect(
      find.text('Medicine 99'),
      findsNothing,
      reason: 'Far demand rows must stay out of the element tree until scrolled.',
    );

    await tester.scrollUntilVisible(
      find.text('Medicine 99'),
      700,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 50,
    );
    expect(find.text('Medicine 99'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
