import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/search.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/removed_stock_screen.dart';

class _RemovedBrowseRecordingController extends PharmacyController {
  _RemovedBrowseRecordingController(InventoryStorage storage)
    : super(
        storage,
        clock: () => DateTime(2026, 9, 20, 12),
        backgroundSearch: false,
      );

  final browseLimits = <int>[];

  @override
  Future<List<SearchHit>> browseArchived({required int limit}) {
    browseLimits.add(limit);
    return super.browseArchived(limit: limit);
  }
}

void main() {
  testWidgets(
    'removed stock exposes paging and resets it on rapid query changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final medicines = List<Medicine>.generate(
        121,
        (index) => archiveMedicine(
          Medicine(
            id: 'removed-$index',
            name: 'Removed Medicine $index',
            strength: '500mg',
            form: 'Tablet',
            expiry: DateTime(2027, 1, 1),
            quantity: 10,
          ),
          reason: 'Damaged pack',
          at: DateTime(2026, 9, 20, 10).add(Duration(seconds: index)),
        ),
        growable: false,
      );
      final controller = _RemovedBrowseRecordingController(
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
          home: RemovedStockScreen(controller: controller),
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
      expect(find.text('Load more'), findsOneWidget);
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
            'Changing query intent must retire the expanded archive window even '
            'when the fuzzy search is cancelled before its debounce fires.',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'exact full removed-stock page does not expose phantom Load more',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final medicines = List<Medicine>.generate(
        120,
        (index) => archiveMedicine(
          Medicine(
            id: 'exact-removed-$index',
            name: 'Exact Removed $index',
            strength: '500mg',
            form: 'Tablet',
            expiry: DateTime(2027, 1, 1),
            quantity: 10,
          ),
          reason: 'Damaged pack',
          at: DateTime(2026, 9, 20, 10).add(Duration(seconds: index)),
        ),
        growable: false,
      );
      final controller = _RemovedBrowseRecordingController(
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
          home: RemovedStockScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.browseLimits, <int>[121]);
      expect(find.text('Load more'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
