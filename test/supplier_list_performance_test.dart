import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/supplier.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/supplier_screen.dart';

void main() {
  testWidgets('supplier directory lazily builds large supplier lists', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final suppliers = <String, Supplier>{};
    for (var index = 0; index < 240; index++) {
      final supplier = Supplier(
        id: 'supplier-$index',
        name: 'Supplier ${index.toString().padLeft(3, '0')}',
        returnBeforeExpiryDays: 30,
      );
      suppliers[supplier.id] = supplier;
    }

    final controller = PharmacyController(
      MemoryInventoryStorage(InventorySnapshot(suppliers: suppliers)),
      clock: () => DateTime(2026, 9, 20, 12),
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: SupplierScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView).first);
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
    expect(find.text('Supplier 000'), findsOneWidget);
    expect(
      find.text('Supplier 099'),
      findsNothing,
      reason:
          'A far supplier row must stay outside the element tree until it nears the viewport.',
    );

    await tester.scrollUntilVisible(
      find.text('Supplier 099'),
      700,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );

    expect(find.text('Supplier 099'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
