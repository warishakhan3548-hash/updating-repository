import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
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
      await tester.pumpAndSettle();

      expect(openedSection, AppSection.stock);
      expect(find.text('Why remove Dolo?'), findsOneWidget);
      expect(controller.snapshot.records[medicine.id]!.archived, isFalse);

      await tester.tap(find.text('Damaged'));
      await tester.pumpAndSettle();
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
    },
  );
}
