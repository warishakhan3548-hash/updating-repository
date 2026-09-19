import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/inventory.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/search.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/search_screen.dart';

class _BrowseRecordingController extends PharmacyController {
  _BrowseRecordingController(InventoryStorage storage)
    : super(
        storage,
        clock: () => DateTime(2026, 9, 20, 12),
        backgroundSearch: false,
      );

  final browseLimits = <int>[];
  Completer<void>? _nextBrowseGate;

  Completer<void> gateNextBrowse() {
    if (_nextBrowseGate != null) {
      throw StateError('A browse refresh is already gated.');
    }
    final gate = Completer<void>();
    _nextBrowseGate = gate;
    return gate;
  }

  @override
  Future<List<SearchHit>> browse(
    SearchScope scope, {
    required int limit,
  }) async {
    browseLimits.add(limit);
    final gate = _nextBrowseGate;
    if (gate != null) {
      _nextBrowseGate = null;
      await gate.future;
    }
    return super.browse(scope, limit: limit);
  }
}

void main() {
  testWidgets(
    'rapid type then clear resets an expanded inventory browse window',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final medicines = List<Medicine>.generate(
        121,
        (index) => Medicine(
          id: 'browse-$index',
          name: 'Medicine $index',
          strength: '500mg',
          form: 'Tablet',
          expiry: DateTime(2027, 1, 1),
          quantity: 10,
        ),
        growable: false,
      );
      final controller = _BrowseRecordingController(
        MemoryInventoryStorage(
          InventorySnapshot(
            records: {
              for (final medicine in medicines) medicine.id: medicine,
            },
          ),
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

      expect(controller.browseLimits, <int>[121]);

      await tester.scrollUntilVisible(
        find.text('Load more'),
        900,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(controller.browseLimits.last, 241);

      await tester.scrollUntilVisible(
        find.byType(TextField),
        -900,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
      final query = find.byType(TextField).first;
      await tester.enterText(query, 'M');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(query, '');
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pumpAndSettle();

      expect(
        controller.browseLimits.last,
        121,
        reason:
            'Query intent must retire the expanded browse window even when the '
            'typed search is cancelled before its debounce fires.',
      );
      expect(tester.takeException(), isNull);

      // Dispose the controller before widget-test invariants inspect pending
      // timers; addTearDown remains a fallback for earlier assertion failures.
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'exact full inventory page does not expose phantom Load more',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final medicines = List<Medicine>.generate(
        120,
        (index) => Medicine(
          id: 'exact-$index',
          name: 'Exact Medicine $index',
          strength: '500mg',
          form: 'Tablet',
          expiry: DateTime(2027, 1, 1),
          quantity: 10,
        ),
        growable: false,
      );
      final controller = _BrowseRecordingController(
        MemoryInventoryStorage(
          InventorySnapshot(
            records: {
              for (final medicine in medicines) medicine.id: medicine,
            },
          ),
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

      expect(controller.browseLimits, <int>[121]);
      expect(find.text('Load more'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'warning-window refresh retires a card that left the expiry scope',
    (tester) async {
      final medicine = Medicine(
        id: 'warning-context',
        name: 'Drotaverine',
        strength: '80mg',
        form: 'Tablet',
        expiry: DateTime(2026, 9, 25),
        quantity: 10,
      );
      final controller = _BrowseRecordingController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {medicine.id: medicine}),
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: SearchScreen(
            controller: controller,
            scope: SearchScope.shortExpiry,
            database: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      Finder targetCard() => find.byWidgetPredicate(
        (widget) =>
            widget is MedicineCard && widget.record.id == medicine.id,
      );
      expect(targetCard(), findsOneWidget);

      final refresh = controller.gateNextBrowse();
      await controller.setShortWarningDays(3);
      await tester.pump();

      expect(
        targetCard(),
        findsNothing,
        reason:
            'Changing the warning window can move a row out of this scope, so '
            'the old card must stop being tappable before refresh completes.',
      );

      refresh.complete();
      await tester.pumpAndSettle();
      expect(targetCard(), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

}
