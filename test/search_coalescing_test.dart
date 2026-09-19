import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/app.dart';
import '../lib/data/inventory_database.dart';
import '../lib/domain/inventory.dart';
import '../lib/domain/search.dart';
import '../lib/domain/supplier.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/search_screen.dart';
import 'domain_contract.dart';

class _GatedPharmacyController extends PharmacyController {
  _GatedPharmacyController(InventoryStorage storage)
    : super(
        storage,
        clock: () => contractToday,
        backgroundSearch: false,
      );

  final firstSearchGate = Completer<void>();
  final requestedQueries = <String>[];
  bool _blockedFirstQuery = false;

  @override
  Future<List<SearchHit>> search(String raw, SearchScope scope) async {
    final query = raw.trim();
    if (query.isNotEmpty) {
      requestedQueries.add(query);
      if (!_blockedFirstQuery) {
        _blockedFirstQuery = true;
        await firstSearchGate.future;
      }
    }
    return super.search(raw, scope);
  }
}

class _RefreshGatedController extends PharmacyController {
  _RefreshGatedController(InventoryStorage storage)
    : super(
        storage,
        clock: () => contractToday,
        backgroundSearch: false,
      );

  Completer<void>? _nextSearchGate;
  int searchRequests = 0;

  Completer<void> gateNextSearch() {
    if (_nextSearchGate != null) {
      throw StateError('A search refresh is already gated.');
    }
    final gate = Completer<void>();
    _nextSearchGate = gate;
    return gate;
  }

  @override
  Future<List<SearchHit>> search(String raw, SearchScope scope) async {
    if (raw.trim().isNotEmpty) searchRequests++;
    final gate = _nextSearchGate;
    if (raw.trim().isNotEmpty && gate != null) {
      _nextSearchGate = null;
      await gate.future;
    }
    return super.search(raw, scope);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'rapid typing coalesces queued searches to the latest query',
    (tester) async {
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
      ];
      final controller = _GatedPharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(
            records: {
              for (final medicine in records) medicine.id: medicine,
            },
          ),
        ),
      );
      await controller.initialize();

      await tester.pumpWidget(PharmacyApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stock').last);
      await tester.pumpAndSettle();

      final query = find.descendant(
        of: find.byType(SearchScreen),
        matching: find.byType(TextField),
      ).first;

      await tester.enterText(query, 'Dro');
      await tester.pump(const Duration(milliseconds: 160));
      expect(controller.requestedQueries, <String>['Dro']);

      await tester.enterText(query, 'Drot');
      await tester.pump(const Duration(milliseconds: 160));
      await tester.enterText(query, 'Drotaverine');
      await tester.pump(const Duration(milliseconds: 160));

      expect(controller.requestedQueries, <String>['Dro']);

      controller.firstSearchGate.complete();
      await tester.pumpAndSettle();

      expect(
        controller.requestedQueries,
        <String>['Dro', 'Drotaverine'],
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is MedicineCard &&
              widget.record.name == 'Drotaverine',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is MedicineCard &&
              widget.record.name == 'Azithromycin',
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
  testWidgets(
    'metadata-only snapshot changes do not restart an active stock query',
    (tester) async {
      final record = stock(
        'metadata-search-target',
        name: 'Drotaverine',
        strength: '80mg',
        expiry: '2027-01-01',
        quantity: 10,
      );
      final controller = _RefreshGatedController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {record.id: record}),
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: SearchScreen(
            controller: controller,
            scope: SearchScope.all,
            database: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final query = find.byType(TextField).first;
      await tester.enterText(query, 'Drotaverine');
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pumpAndSettle();
      expect(controller.searchRequests, 1);

      await controller.saveSupplier(
        const Supplier(
          id: 'supplier_search_metadata',
          name: 'Metadata Supplier',
          returnBeforeExpiryDays: 30,
        ),
        expectedRevision: controller.snapshot.revision,
      );
      await tester.pumpAndSettle();

      expect(
        controller.searchRequests,
        1,
        reason:
            'Supplier metadata does not change medicine search membership or ordering.',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is MedicineCard && widget.record.id == record.id,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'same-query refresh keeps stock-only hits but retires stale searchable hits',
    (tester) async {
      final record = stock(
        'refresh-target',
        name: 'Drotaverine',
        strength: '80mg',
        expiry: '2027-01-01',
        quantity: 10,
      );
      final controller = _RefreshGatedController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {record.id: record}),
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: SearchScreen(
            controller: controller,
            scope: SearchScope.all,
            database: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final query = find.byType(TextField).first;
      await tester.enterText(query, 'Drotaverine');
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pumpAndSettle();

      Finder targetCard() => find.byWidgetPredicate(
        (widget) =>
            widget is MedicineCard && widget.record.id == record.id,
      );
      expect(targetCard(), findsOneWidget);

      final quantityRefresh = controller.gateNextSearch();
      var live = controller.snapshot.records[record.id]!;
      await controller.save(
        live.patch({'quantity': 9}),
        expectedRevision: controller.snapshot.revision,
      );
      await tester.pump();
      expect(
        targetCard(),
        findsOneWidget,
        reason:
            'Quantity-only edits do not change search membership, so the valid '
            'card should stay visible while the same query refreshes.',
      );
      quantityRefresh.complete();
      await tester.pumpAndSettle();

      final searchableRefresh = controller.gateNextSearch();
      live = controller.snapshot.records[record.id]!;
      await controller.save(
        live.patch({'name': 'Cefixime'}),
        expectedRevision: controller.snapshot.revision,
      );
      await tester.pump();
      expect(
        targetCard(),
        findsNothing,
        reason:
            'A row that no longer matches the published search projection must '
            'not remain tappable under the old query while refresh is pending.',
      );
      searchableRefresh.complete();
      await tester.pumpAndSettle();
      expect(targetCard(), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

}
