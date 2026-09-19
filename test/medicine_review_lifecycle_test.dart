import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/medicine_review_pipeline.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/medicine_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'covered medicine review defers rematching until the route is active',
    (tester) async {
      final medicine = Medicine(
        id: 'review-lifecycle-stock',
        name: 'Dolo 650',
        quantity: 10,
        expiry: DateTime(2027, 6, 1),
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(
            records: <String, Medicine>{medicine.id: medicine},
          ),
        ),
        clock: () => DateTime(2026, 9, 20, 10),
        backgroundSearch: false,
      );
      await controller.initialize();

      const draft = MedicineScanDraft(
        fields: <String, ExtractedMedicineField>{
          'name': ExtractedMedicineField(
            value: 'Dolo 650',
            confidence: .98,
            support: 2,
          ),
        },
        rawText: 'DOLO 650',
        searchKeywords: 'dolo 650',
        frameSequences: <int>[0],
        overallConfidence: .98,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: MedicineReviewScreen(
            controller: controller,
            input: const MedicineReviewInput.prepared(
              <MedicineScanDraft>[draft],
              singlePackExpected: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final initialBuilds = controller.debugWebSearchIndexBuilds;
      expect(initialBuilds, greaterThan(0));

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Cover review')),
        ),
      );
      await tester.pumpAndSettle();

      await controller.save(
        Medicine(
          id: 'review-lifecycle-other-stock',
          name: 'Other Medicine',
          quantity: 4,
          expiry: DateTime(2027, 7, 1),
        ),
        expectedRevision: controller.snapshot.revision,
      );
      await tester.pumpAndSettle();

      expect(
        controller.debugWebSearchIndexBuilds,
        initialBuilds,
        reason:
            'A covered medicine review must not rebuild its fuzzy index behind another route.',
      );

      navigator.pop();
      await tester.pumpAndSettle();

      expect(
        controller.debugWebSearchIndexBuilds,
        initialBuilds + 1,
        reason:
            'Returning to review must catch up once from the new medicine dataset.',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
