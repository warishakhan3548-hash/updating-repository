import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/tracking.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/stats_screen.dart';

void main() {
  testWidgets('sold tracker lazily builds a large medicine ranking', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sales = <String, SaleEvent>{};
    for (var index = 0; index < 240; index++) {
      final sale = SaleEvent(
        id: 'sale-$index',
        stockId: 'stock-$index',
        medicineName: 'Medicine ${index.toString().padLeft(3, '0')}',
        quantity: 1,
        occurredAt: DateTime(2026, 9, 19, 12),
      );
      sales[sale.id] = sale;
    }

    final controller = PharmacyController(
      MemoryInventoryStorage(InventorySnapshot(sales: sales)),
      clock: () => DateTime(2026, 9, 19, 12),
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: StatsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final tracker = find.text('Sold Medicine Tracker');
    await tester.ensureVisible(tracker);
    await tester.pumpAndSettle();
    await tester.tap(tracker);
    await tester.pumpAndSettle();

    expect(find.text('Medicine 000'), findsOneWidget);
    expect(
      find.text('Medicine 099'),
      findsNothing,
      reason:
          'A far ranking row must stay outside the element tree until it nears the viewport.',
    );

    await tester.scrollUntilVisible(
      find.text('Medicine 099'),
      700,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 40,
    );

    expect(find.text('Medicine 099'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // PharmacyController owns a civil-day timer. Dispose it before Flutter's
    // widget-test invariant check rather than relying on post-test tearDown.
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
