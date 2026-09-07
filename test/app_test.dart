import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/app.dart';
import '../lib/data/inventory_database.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/search_screen.dart';
import '../lib/ui/editor_screen.dart';
import '../lib/ui/backup_screen.dart';
import '../lib/ui/import_screen.dart';
import '../lib/ui/design.dart';
import '../lib/domain/inventory.dart';
import 'domain_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Manrope',
    )..addFont(rootBundle.load('assets/fonts/Manrope.ttf'))).load();
    await (FontLoader(
      'NotoSansDevanagari',
    )..addFont(rootBundle.load('assets/fonts/NotoSansDevanagari.ttf'))).load();
  });
  Future<PharmacyController> seeded() async {
    final records = [
      stock(
        'short',
        name: 'Azithromycin',
        expiry: '2026-09-10',
        salt: 'Azithromycin',
      ),
      stock(
        'month',
        name: 'Drotaverine',
        strength: '80mg',
        expiry: '2026-10-22',
        salt: 'Drotaverine',
      ),
      stock(
        'expired',
        name: 'Cefixime',
        strength: '200mg',
        expiry: '2026-09-05',
      ),
      stock('sold', name: 'Dolo', strength: '650mg', sold: true),
      stock(
        'normal',
        name: 'Pantoprazole',
        strength: '40mg',
        expiry: '2027-10',
      ),
    ];
    final c = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(records: {for (final m in records) m.id: m}),
      ),
      clock: () => contractToday,
      backgroundSearch: false,
    );
    await c.initialize();
    return c;
  }

  Future<void> screenshot(
    WidgetTester tester,
    GlobalKey key,
    String name,
  ) async {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/ui-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('Home renders at phone size and opens only expired stock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await seeded();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: PharmacyApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Aaris Pharmacy'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await screenshot(tester, key, 'home');
    await tester.ensureVisible(find.text('Expired Medicines'));
    await tester.tap(find.text('Expired Medicines'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.text('Cefixime'), findsOneWidget);
    expect(find.text('Azithromycin'), findsNothing);
    await screenshot(tester, key, 'expired-search');
    await tester.tap(find.text('Cefixime'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.text('Medicine details'), findsOneWidget);
    await screenshot(tester, key, 'medicine-details');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('Database add flow saves a name-only entry and updates Home', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      backgroundSearch: false,
    );
    await controller.initialize();
    await tester.pumpWidget(PharmacyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Database'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add / Import medicines'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add manually'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'New medicine');
    await tester.ensureVisible(find.text('Save medicine'));
    await tester.tap(find.text('Save medicine'));
    await tester.pumpAndSettle();
    expect(controller.records.single.name, 'New medicine');
    expect(controller.records.single.quantity, isNull);
    expect(controller.list(SearchScope.shortExpiry), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('All main tabs fit a narrow phone at large text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = await seeded();
    await tester.pumpWidget(PharmacyApp(controller: c));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final tab in ['Database', 'AI', 'Calculator', 'Profile']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Overflow in $tab');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  testWidgets('Tracking and AI hub have reviewable screenshots', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await seeded();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: PharmacyApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calculator'));
    await tester.pumpAndSettle();
    await screenshot(tester, key, 'tracking');
    await tester.tap(find.text('AI').last);
    await tester.pumpAndSettle();
    await screenshot(tester, key, 'ai-controller');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  testWidgets(
    'Database, Profile, import and backup share the same visual system',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await seeded();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: PharmacyApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      for (final tab in ['Database', 'Profile']) {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot(tester, key, tab.toLowerCase());
      }
      for (final entry in <String, Widget>{
        'import': ImportCenterScreen(controller: c),
        'backup': BackupScreen(controller: c),
      }.entries) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              theme: pharmacyTheme(),
              builder: (context, child) => PharmacyBackdrop(child: child!),
              home: entry.value,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot(tester, key, entry.key);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
