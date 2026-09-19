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

  void publishNonInventoryChangeForTest() => notifyListeners();

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
      batchNumber: 'DROT-A',
    ),
    reason: 'Removed for return',
    at: DateTime.utc(2026, 9, 18, 10),
  );
  final azithromycin = archiveMedicine(
    stock(
      'removed-azithromycin',
      name: 'Azithromycin',
      strength: '500mg',
      batchNumber: 'AZI-A',
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

      // Dispose the widget and its app-scoped controller before flutter_test's
      // pending-timer invariant runs. The controller intentionally owns a
      // midnight rollover timer for its full application lifetime.
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'removed-stock search ignores non-inventory controller notifications',
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

      expect(controller.requestedQueries, <String>['Drotaverine']);
      expect(find.text('Drotaverine'), findsOneWidget);

      // AI preparation/progress and other controller-only UI notifications do
      // not change the immutable inventory snapshot. Removed-stock discovery
      // must stay idle instead of repeating the same fuzzy search.
      controller.publishNonInventoryChangeForTest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(controller.requestedQueries, <String>['Drotaverine']);
      expect(find.text('Drotaverine'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'covered removed-stock screen cancels pending query work and resumes once',
    (tester) async {
      final controller = await _controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_screen(controller));
      await tester.pumpAndSettle();

      final query = find.byType(TextField).first;
      await tester.enterText(query, 'Drotaverine');

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) =>
                const Scaffold(body: Center(child: Text('Covered route'))),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // The 150 ms debounce would have entered fuzzy search here if the covered
      // route still owned a live listener/timer.
      expect(controller.requestedQueries, isEmpty);

      navigator.pop();
      await tester.pump();
      await tester.pump();

      // Reactivation retries the current query once, rather than replaying the
      // cancelled debounce and then starting a second refresh.
      expect(controller.requestedQueries, <String>['Drotaverine']);

      controller.firstSearchGate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Drotaverine'), findsOneWidget);
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
