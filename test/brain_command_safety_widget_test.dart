import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/brain_screen.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'negated Brain mutation is stopped before navigation, review or storage write',
    (tester) async {
      final medicine = Medicine.fromJson({
        'id': 'intent-firewall-dolo',
        'name': 'Dolo',
        'strength': '650mg',
        'expiry': '2027-12',
        'quantity': 10,
      });
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {medicine.id: medicine}),
        ),
        clock: () => DateTime(2026, 9, 10, 8, 30),
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
        'Dolo 650 delete mat karo',
      );
      await tester.tap(find.byTooltip('Run command').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('negative instruction'), findsOneWidget);
      expect(openedSection, isNull);
      expect(controller.snapshot.revision, beforeRevision);
      expect(controller.snapshot.records[medicine.id]!.archived, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );
}
