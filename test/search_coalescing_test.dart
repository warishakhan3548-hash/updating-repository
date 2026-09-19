import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/app.dart';
import '../lib/data/inventory_database.dart';
import '../lib/domain/inventory.dart';
import '../lib/domain/search.dart';
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
}
