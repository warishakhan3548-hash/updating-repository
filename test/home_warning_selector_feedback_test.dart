import 'dart:async';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FeedbackStorage implements InventoryStorage {
  _FeedbackStorage([InventorySnapshot? initial])
    : _inner = MemoryInventoryStorage(initial);

  final MemoryInventoryStorage _inner;
  final Completer<void> _gate = Completer<void>();
  int commits = 0;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<InventorySnapshot> load() => _inner.load();

  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) async {
    commits++;
    await _gate.future;
    return _inner.commit(mutation);
  }

  @override
  Future<void> close() => _inner.close();
}

void main() {
  testWidgets('warning selector acknowledges a tap before persistence completes',
      (tester) async {
    final medicine = Medicine(
      id: 'pending-window',
      name: 'Pending Window',
      expiry: DateTime(2026, 9, 26),
      quantity: 10,
    );
    final storage = _FeedbackStorage(
      InventorySnapshot(records: <String, Medicine>{medicine.id: medicine}),
    );
    final controller = PharmacyController(
      storage,
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeScreen(controller: controller, onDatabase: () {}),
          ),
        ),
      );

      expect(controller.settings.shortDays, 8);
      await tester.tap(find.byType(PopupMenuButton<int>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 Days'));
      await tester.pump(const Duration(milliseconds: 50));

      expect(storage.commits, 1);
      expect(controller.settings.shortDays, 8);
      expect(find.text('5d'), findsOneWidget);
      expect(find.text('8d'), findsNothing);
      expect(find.text('5 Days Left'), findsOneWidget);
      expect(find.text('8 Days Left'), findsNothing);
      expect(
        tester.widget<MedicineCard>(find.byType(MedicineCard)).settings.shortDays,
        5,
      );
      expect(find.byIcon(Icons.sync_rounded), findsOneWidget);

      storage.release();
      await tester.pumpAndSettle();

      expect(controller.settings.shortDays, 5);
      expect(find.text('5d'), findsOneWidget);
      expect(find.text('5 Days Left'), findsOneWidget);
      expect(
        tester.widget<MedicineCard>(find.byType(MedicineCard)).settings.shortDays,
        5,
      );
      expect(find.byIcon(Icons.sync_rounded), findsNothing);
    } finally {
      storage.release();
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
