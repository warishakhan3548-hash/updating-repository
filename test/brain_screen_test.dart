import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/operational_context.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/brain_screen.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(
  String id, {
  String name = 'Paracetamol',
  String strength = '500mg',
  String expiry = '2026-09-10',
  String barcode = '',
  String batchNumber = '',
  String notes = '',
  String salt = '',
  int? quantity = 10,
  int? price = 200,
  String form = 'Tablet',
  bool sold = false,
  String location = '',
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'expiry': expiry,
  'barcode': barcode,
  'batchNumber': batchNumber,
  'notes': notes,
  'salt': salt,
  'quantity': sold ? 0 : quantity,
  'unitPricePaise': price,
  'form': form,
  'sold': sold,
  'location': location,
});

final _today = DateTime(2026, 9, 7, 23, 59);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'exact Brain remove command opens protected action and never mutates before confirmation',
    (tester) async {
      final medicine = _stock(
        'brain-remove-target',
        name: 'Dolo',
        strength: '650mg',
        barcode: '9988776655',
        expiry: '2027-12',
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {medicine.id: medicine}),
        ),
        clock: () => _today,
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      AppSection? openedSection;
      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: Scaffold(
            body: BrainScreen(
              controller: controller,
              onOpenSection: (section) => openedSection = section,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).first,
        '9988776655 delete karo',
      );
      await tester.tap(find.byTooltip('Run command').first);
      // The command deliberately remains busy while its protected dialog is
      // open, so pumpAndSettle would wait on the progress indicator forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(openedSection, AppSection.stock);
      expect(find.text('Why remove Dolo?'), findsOneWidget);
      expect(controller.snapshot.records[medicine.id]!.archived, isFalse);

      await tester.tap(find.text('Damaged'));
      // A second protected confirmation is now open while the command is still
      // busy. Use bounded pumps again and assert the no-mutation boundary.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Remove Dolo?'), findsOneWidget);
      expect(controller.snapshot.records[medicine.id]!.archived, isFalse);

      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      // The Brain contains a deliberate busy progress animation while the async
      // controller transaction is finishing, so a fixed pump is more precise
      // than pumpAndSettle (which waits for every animation to become idle).
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.snapshot.records[medicine.id]!.archived, isTrue);
      expect(controller.canUndo, isTrue);
      expect(tester.takeException(), isNull);

      // Widget-test teardown hooks run after Flutter verifies that no timers are
      // pending. Unmount first, then synchronously dispose the controller so its
      // midnight refresh timer is cancelled before that invariant is checked.
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'Brain answers product stock and contextual expiry read-only from authoritative rows',
    (tester) async {
      final first = _stock(
        'dolo-a',
        name: 'Dolo',
        strength: '650mg',
        expiry: '2026-10-01',
        batchNumber: 'A1',
        salt: 'Paracetamol',
        quantity: 10,
        location: 'Rack A',
      );
      final second = _stock(
        'dolo-b',
        name: 'Dolo',
        strength: '650mg',
        expiry: '2026-11-01',
        batchNumber: 'B1',
        salt: 'Paracetamol',
        quantity: 20,
        location: 'Rack B',
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {first.id: first, second.id: second}),
        ),
        clock: () => _today,
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      AppSection? openedSection;
      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: Scaffold(
            body: BrainScreen(
              controller: controller,
              onOpenSection: (section) => openedSection = section,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final beforeRevision = controller.snapshot.revision;
      await tester.enterText(
        find.byType(TextField).first,
        'Dolo 650 stock kitna hai',
      );
      await tester.tap(find.byTooltip('Run command').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.textContaining('30 known units across 2 current batches'),
        findsOneWidget,
      );
      expect(controller.snapshot.revision, beforeRevision);
      expect(openedSection, isNull);
      expect(controller.operationalTarget?.identity, first.identity);

      await tester.enterText(
        find.byType(TextField).first,
        'iska expiry kab hai',
      );
      await tester.tap(find.byTooltip('Run command').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.textContaining('earliest recorded valid expiry is 2026-10-01'),
        findsOneWidget,
      );
      expect(controller.snapshot.revision, beforeRevision);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );
}
