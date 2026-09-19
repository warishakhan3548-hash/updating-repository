import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct SOLD save validates and audits one authoritative instant', () async {
    final fallback = DateTime(2026, 9, 19, 12);
    final scripted = <DateTime>[];
    DateTime clock() => scripted.isEmpty ? fallback : scripted.removeAt(0);

    final active = Medicine(
      id: 'midnight-sold',
      name: 'Midnight Test',
      strength: '500mg',
      form: 'Tablet',
      quantity: 1,
      expiry: DateTime(2026, 9, 19),
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(records: <String, Medicine>{active.id: active}),
      ),
      clock: clock,
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    scripted.addAll(<DateTime>[
      DateTime(2026, 9, 19, 23, 59, 59),
      DateTime(2026, 9, 20, 0, 0, 1),
    ]);
    await controller.save(
      active.patch(<String, dynamic>{
        'sold': true,
        'quantity': 0,
        'soldAt': '2026-09-19T23:59:59',
        'soldQuantity': 1,
      }),
      expectedRevision: controller.snapshot.revision,
    );

    expect(controller.snapshot.events.first['businessDay'], '2026-09-19');
  });
}
