import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/search.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/removed_stock_screen.dart';
import 'domain_contract.dart';

class _GatedRemovedStockController extends PharmacyController {
  _GatedRemovedStockController(InventoryStorage storage)
    : super(
        storage,
        clock: () => contractToday,
        backgroundSearch: false,
      );

  final firstSearchGate = Completer<void>();
  final requestedQueries = <String>[];
  bool _blockedFirstQuery = false;

  @override
  Future<List<SearchHit>> searchArchived(String raw) async {
    final query = raw.trim();
    if (query.isNotEmpty) {
      requestedQueries.add(query);
      if (!_blockedFirstQuery) {
        _blockedFirstQuery = true;
        await firstSearchGate.future;
      }
    }
    return super.searchArchived(raw);
  }
}

InventorySnapshot _removedInventory() {
  final drotaverine = archiveMedicine(
    stock(
      'removed-drotaverine',
      name: 'Drotaverine',
      strength: '80mg',
      batch: 'DROT-A',
    ),
    reason: 'Removed for return',
    at: DateTime.utc(2026, 9, 18, 10),
  );
  final azithromycin = archiveMedicine(
    stock(
      'removed-azithromycin',
      name: 'Azithromycin',
      strength: '500mg',
      batch: 'AZI-A',
    ),
    reason: 'Removed for return',
    at: DateTime.utc(2026, 9, 19, 10),
  );
  return InventorySnapshot(
    records: {
      drotaverine.id: drotaverine,
      azithromycin.id: azithromycin,
    },
  );
}

Future<_GatedRemovedStockController> _controller() async {
  final controller = _GatedRemovedStockController(
    MemoryInventoryStorage(_removedInventory()),
  );
  await controller.initialize();
  return controller;
}

Widget _screen(PharmacyController controller) => MaterialApp(
  theme: pharmacyTheme(),
  home: RemovedStockScreen(controller: controller),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'rapid removed-stock typing coalesces queued searches to the latest query',
    (tester) async {
      final controller = await _controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_screen(controller));
      await tester.pumpAndSettle();

      final query = find.byType(TextField).first;
      await tester.enterText(query, 'Dro');
      await tester.pump(const Duration(milliseconds: 160));
      expect(controller.requestedQueries, <String>['Dro']);

      await tester.enterText(query, 'Drota');
      await tester.pump(const Duration(milliseconds: 160));
      await tester.enterText(query, 'Drotaverine');
      await tester.pump(const Duration(milliseconds: 160));

      // The first fuzzy query is already running. The intermediate generations
      // stay local to the screen instead of becoming expensive worker requests.
      expect(controller.requestedQueries, <String>['Dro']);

      controller.firstSearchGate.complete();
      await tester.pumpAndSettle();

      expect(
        controller.requestedQueries,
        <String>['Dro', 'Drotaverine'],
      );
      expect(find.text('Drotaverine'), findsOneWidget);
      expect(find.text('Azithromycin'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'changing a removed-stock query clears stale restore rows immediately',
    (tester) async {
      final controller = await _controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_screen(controller));
      await tester.pumpAndSettle();

      final query = find.byType(TextField).first;
      await tester.enterText(query, 'Drotaverine');
      await tester.pump(const Duration(milliseconds: 160));
      controller.firstSearchGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Drotaverine'), findsOneWidget);
      expect(find.text('Azithromycin'), findsNothing);

      await tester.enterText(query, 'Azithromycin');
      await tester.pump();

      // The old exact-row Restore action must disappear before the new search
      // starts; it must never remain tappable under different query text.
      expect(find.text('Drotaverine'), findsNothing);

      await tester.pump(const Duration(milliseconds: 160));
      await tester.pumpAndSettle();
      expect(find.text('Azithromycin'), findsOneWidget);
      expect(find.text('Drotaverine'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
