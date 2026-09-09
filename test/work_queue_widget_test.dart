import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/editor_screen.dart';
import '../lib/ui/work_queue_screen.dart';

void main() {
  testWidgets('work queue opens the exact priority stock record', (tester) async {
    final expired = Medicine.fromJson({
      'id': 'expired-id',
      'name': 'Cefixime',
      'strength': '200mg',
      'form': 'Tablet',
      'expiry': '2026-09-08',
      'quantity': 7,
      'location': 'B1 · R2',
    });
    final safe = Medicine.fromJson({
      'id': 'safe-id',
      'name': 'Paracetamol',
      'strength': '500mg',
      'form': 'Tablet',
      'expiry': '2027-12-31',
      'quantity': 20,
      'location': 'B2 · R1',
    });
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          records: {expired.id: expired, safe.id: safe},
        ),
      ),
      clock: () => DateTime(2026, 9, 9, 12),
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: WorkQueueScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pharmacist priorities'), findsOneWidget);
    expect(find.text('Cefixime · 200mg'), findsOneWidget);
    expect(find.text('Critical'), findsOneWidget);
    expect(find.text('Paracetamol · 500mg'), findsNothing);

    await tester.tap(find.text('Cefixime · 200mg'));
    await tester.pumpAndSettle();

    final editor = tester.widget<EditorScreen>(find.byType(EditorScreen));
    expect(editor.record?.id, 'expired-id');
  });
}
