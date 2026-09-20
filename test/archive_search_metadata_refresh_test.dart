import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/search.dart';
import '../lib/domain/supplier.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/removed_stock_screen.dart';
import 'domain_contract.dart';

class _ArchiveSearchRecordingController extends PharmacyController {
  _ArchiveSearchRecordingController(InventoryStorage storage)
    : super(
        storage,
        clock: () => contractToday,
        backgroundSearch: false,
      );

  int queryCount = 0;

  @override
  Future<List<SearchHit>> searchArchived(String raw) {
    if (raw.trim().isNotEmpty) queryCount++;
    return super.searchArchived(raw);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'archive search stays idle for unrelated metadata while active and covered',
    (tester) async {
      final medicine = archiveMedicine(
        stock(
          'archive-refresh-target',
          name: 'Drotaverine',
          strength: '80mg',
          quantity: 10,
        ),
        reason: 'Return to supplier',
        at: DateTime.utc(2026, 9, 19, 10),
      );
      final controller = _ArchiveSearchRecordingController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {medicine.id: medicine}),
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: RemovedStockScreen(
            controller: controller,
            initialQuery: 'Drotaverine',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.queryCount, 1);
      expect(find.text('Drotaverine'), findsOneWidget);

      await controller.saveSupplier(
        const Supplier(
          id: 'archive-refresh-supplier',
          name: 'Metadata Supplier',
          returnBeforeExpiryDays: 30,
        ),
        expectedRevision: controller.snapshot.revision,
      );
      await tester.pumpAndSettle();

      expect(
        controller.queryCount,
        1,
        reason: 'Supplier metadata does not change archived search projection.',
      );

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final covered = navigator.push<void>(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) =>
              const Scaffold(body: Center(child: Text('Covered route'))),
        ),
      );
      await tester.pumpAndSettle();

      final nextDays = controller.settings.shortDays == 5 ? 8 : 5;
      await controller.setShortWarningDays(nextDays);
      await tester.pump();

      navigator.pop();
      await covered;
      await tester.pumpAndSettle();

      expect(
        controller.queryCount,
        1,
        reason: 'Settings-only writes must not restart archive search on resume.',
      );
      expect(find.text('Drotaverine'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
