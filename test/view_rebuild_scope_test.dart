import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/supplier.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/demand_history_sheet.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/home_screen.dart';
import 'package:aaris_pharmacy/ui/order_screen.dart';
import 'package:aaris_pharmacy/ui/profile_screen.dart';
import 'package:aaris_pharmacy/ui/stats_screen.dart';
import 'package:aaris_pharmacy/ui/supplier_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PharmacyController controllerWith(InventorySnapshot snapshot) =>
      PharmacyController(
        MemoryInventoryStorage(snapshot),
        clock: () => DateTime(2026, 9, 20, 10),
        backgroundSearch: false,
      );

  testWidgets('Home stays frame-quiet for supplier-only writes', (tester) async {
    final controller = controllerWith(InventorySnapshot());
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: Scaffold(
          body: HomeScreen(controller: controller, onDatabase: () {}),
        ),
      ),
    );
    await tester.pump();

    final title = find.text('Aaris Pharmacy');
    final before = tester.widget<Text>(title);

    await controller.saveSupplier(
      const Supplier(
        id: 'home-quiet-supplier',
        name: 'Home Quiet Supplier',
        returnBeforeExpiryDays: 30,
      ),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(
      tester.widget<Text>(title),
      same(before),
      reason: 'Supplier metadata is outside the Home projection.',
    );

    final nextDays = controller.settings.shortDays == 5 ? 8 : 5;
    await controller.setShortWarningDays(nextDays);
    await tester.pump();

    expect(
      tester.widget<Text>(title),
      isNot(same(before)),
      reason: 'A warning-window change must rebuild Home.',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Supplier directory ignores warning-only publications', (
    tester,
  ) async {
    const supplier = Supplier(
      id: 'supplier-directory-quiet',
      name: 'Supplier Directory Quiet',
      returnBeforeExpiryDays: 30,
    );
    final controller = controllerWith(
      InventorySnapshot(
        suppliers: <String, Supplier>{supplier.id: supplier},
      ),
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: SupplierScreen(controller: controller),
      ),
    );
    await tester.pump();

    final summary = find.text('1 supplier · 0 return due');
    final before = tester.widget<Text>(summary);

    final nextDays = controller.settings.shortDays == 5 ? 8 : 5;
    await controller.setShortWarningDays(nextDays);
    await tester.pump();

    expect(
      tester.widget<Text>(summary),
      same(before),
      reason: 'Warning settings do not affect supplier return projections.',
    );

    await controller.saveSupplier(
      supplier.patch(<String, dynamic>{'name': 'Supplier Directory Updated'}),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(tester.widget<Text>(summary), isNot(same(before)));
    expect(find.text('Supplier Directory Updated'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Supplier detail ignores warning-only publications', (
    tester,
  ) async {
    const supplier = Supplier(
      id: 'supplier-detail-quiet',
      name: 'Supplier Detail Quiet',
      returnBeforeExpiryDays: 30,
    );
    final controller = controllerWith(
      InventorySnapshot(
        suppliers: <String, Supplier>{supplier.id: supplier},
      ),
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: SupplierDetailScreen(
          controller: controller,
          supplierId: supplier.id,
        ),
      ),
    );
    await tester.pump();

    final name = find.text('Supplier Detail Quiet');
    final before = tester.widget<Text>(name);

    final nextDays = controller.settings.shortDays == 5 ? 8 : 5;
    await controller.setShortWarningDays(nextDays);
    await tester.pump();

    expect(
      tester.widget<Text>(name),
      same(before),
      reason: 'Warning settings do not affect a supplier detail projection.',
    );

    await controller.saveSupplier(
      supplier.patch(<String, dynamic>{'name': 'Supplier Detail Updated'}),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(find.text('Supplier Detail Updated'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Profile ignores stock-only publications', (tester) async {
    final controller = controllerWith(InventorySnapshot());
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: ProfileScreen(controller: controller),
      ),
    );
    await tester.pump();

    final warningLabel =
        '${controller.settings.shortDays} days · ${controller.settings.months} months';
    final warning = find.text(warningLabel);
    final before = tester.widget<Text>(warning);

    await controller.save(
      Medicine(
        id: 'profile-quiet-stock',
        name: 'Profile Quiet Medicine',
        quantity: 4,
        expiry: DateTime(2027, 1, 1),
      ),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(
      tester.widget<Text>(warning),
      same(before),
      reason: 'Medicine writes do not change Profile landing-page content.',
    );

    final nextDays = controller.settings.shortDays == 5 ? 8 : 5;
    await controller.setShortWarningDays(nextDays);
    await tester.pump();

    expect(
      find.text('$nextDays days · ${controller.settings.months} months'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Stats ignores supplier-only writes but reacts to stock changes', (
    tester,
  ) async {
    final controller = controllerWith(InventorySnapshot());
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: StatsScreen(controller: controller),
      ),
    );
    await tester.pump();

    final title = find.text('Pharmacy snapshot');
    final before = tester.widget<Text>(title);

    await controller.saveSupplier(
      const Supplier(
        id: 'stats-quiet-supplier',
        name: 'Stats Quiet Supplier',
        returnBeforeExpiryDays: 30,
      ),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(
      tester.widget<Text>(title),
      same(before),
      reason: 'Supplier metadata does not participate in pharmacy snapshot metrics.',
    );

    await controller.save(
      Medicine(
        id: 'stats-visible-stock',
        name: 'Stats Visible Medicine',
        quantity: 4,
        expiry: DateTime(2027, 1, 1),
      ),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(tester.widget<Text>(title), isNot(same(before)));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Demand history ignores unrelated supplier writes', (tester) async {
    final medicine = Medicine(
      id: 'demand-history-stock',
      name: 'Demand History Medicine',
      quantity: 10,
      expiry: DateTime(2027, 1, 1),
    );
    final controller = controllerWith(
      InventorySnapshot(records: <String, Medicine>{medicine.id: medicine}),
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDemandHistory(
              context,
              controller,
              productKey: medicine.identity,
              title: 'Demand History Medicine',
            ),
            child: const Text('Open demand history'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open demand history'));
    await tester.pumpAndSettle();

    final subtitle = find.text('Demand History Medicine');
    final before = tester.widget<Text>(subtitle);

    await controller.saveSupplier(
      const Supplier(
        id: 'demand-quiet-supplier',
        name: 'Demand Quiet Supplier',
        returnBeforeExpiryDays: 30,
      ),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(
      tester.widget<Text>(subtitle),
      same(before),
      reason: 'Demand history depends on medicine rows, sales and the civil day only.',
    );

    await controller.save(
      Medicine(
        id: 'demand-history-second-stock',
        name: 'Demand History Second Medicine',
        quantity: 3,
        expiry: DateTime(2027, 2, 1),
      ),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(tester.widget<Text>(subtitle), isNot(same(before)));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Order review ignores suppliers but rebuilds for warning policy', (
    tester,
  ) async {
    final controller = controllerWith(InventorySnapshot());
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: OrderScreen(
          controller: controller,
          range: TrackingRange.lastDays(controller.today, 30),
        ),
      ),
    );
    await tester.pump();

    final empty = find.text('अभी कोई नया ऑर्डर सुझाया नहीं गया है।');
    final before = tester.widget<Text>(empty);

    await controller.saveSupplier(
      const Supplier(
        id: 'order-quiet-supplier',
        name: 'Order Quiet Supplier',
        returnBeforeExpiryDays: 30,
      ),
      expectedRevision: controller.snapshot.revision,
    );
    await tester.pump();

    expect(
      tester.widget<Text>(empty),
      same(before),
      reason: 'Supplier metadata is outside reorder and blocker calculations.',
    );

    final nextDays = controller.settings.shortDays == 5 ? 8 : 5;
    await controller.setShortWarningDays(nextDays);
    await tester.pump();

    expect(
      tester.widget<Text>(empty),
      isNot(same(before)),
      reason: 'Warning policy participates in order blocker planning.',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

}
