import 'dart:convert';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/ai_protocol.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

String _envelope({
  required String requestId,
  required String changeId,
  required int baseRevision,
  required List<Map<String, dynamic>> actions,
}) => jsonEncode({
  'schema': pharmacySchema,
  'requestId': requestId,
  'changeId': changeId,
  'baseRevision': baseRevision,
  'reply': 'Prepared for review',
  'actions': actions,
});

Medicine _stock({required String expiry}) => Medicine.fromJson({
  'id': 'stock_1',
  'name': 'Paracetamol',
  'strength': '500mg',
  'form': 'Tablet',
  'expiry': expiry,
  'quantity': 10,
  'unitPricePaise': 250,
});

Future<PharmacyController> _controller(
  Medicine medicine,
  DateTime Function() clock, {
  int revision = 7,
}) async {
  final controller = PharmacyController(
    MemoryInventoryStorage(
      InventorySnapshot(
        revision: revision,
        records: {medicine.id: medicine},
      ),
    ),
    clock: clock,
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  test('AI SOLD revalidates expiry when apply crosses the expiry boundary', () async {
    var now = DateTime(2026, 9, 17, 23, 59);
    final medicine = _stock(expiry: '2026-09-17');
    final controller = await _controller(medicine, () => now);
    addTearDown(controller.dispose);

    final plan = controller.review(
      _envelope(
        requestId: 'session_expiry_crossing',
        changeId: 'change_mark_sold_001',
        baseRevision: controller.snapshot.revision,
        actions: [
          {'op': 'mark_sold', 'id': medicine.id},
        ],
      ),
    );

    now = DateTime(2026, 9, 18, 0, 1);
    await expectLater(
      controller.applyAi(plan, {0}),
      throwsA(isA<FormatException>()),
    );

    final live = controller.snapshot.records[medicine.id]!;
    expect(live.sold, isFalse);
    expect(live.quantity, 10);
    expect(controller.snapshot.revision, 7);
    expect(controller.snapshot.receipts, isNot(contains(plan.requestId)));
  });

  test('AI SOLD stamps lifecycle and audit at the apply instant', () async {
    var now = DateTime(2026, 9, 17, 9);
    final medicine = _stock(expiry: '2026-10-31');
    final controller = await _controller(medicine, () => now);
    addTearDown(controller.dispose);

    final plan = controller.review(
      _envelope(
        requestId: 'session_sold_timestamp',
        changeId: 'change_mark_sold_002',
        baseRevision: controller.snapshot.revision,
        actions: [
          {'op': 'mark_sold', 'id': medicine.id},
        ],
      ),
    );

    final appliedAt = DateTime(2026, 9, 17, 17, 30, 12);
    now = appliedAt;
    await controller.applyAi(plan, {0});

    final live = controller.snapshot.records[medicine.id]!;
    expect(live.sold, isTrue);
    expect(live.quantity, 0);
    expect(live.soldQuantity, 10);
    expect(live.soldUnitPricePaise, 250);
    expect(live.soldAt, appliedAt.toIso8601String());
    expect(
      DateTime.parse(controller.snapshot.events.first['time'] as String).toUtc(),
      appliedAt.toUtc(),
    );
    expect(
      controller.snapshot.events.first['businessDay'],
      dateText(appliedAt),
    );
  });

  test('AI removal stamps archivedAt and audit at the same apply instant', () async {
    var now = DateTime(2026, 9, 17, 9);
    final medicine = _stock(expiry: '2026-10-31');
    final controller = await _controller(medicine, () => now);
    addTearDown(controller.dispose);

    final plan = controller.review(
      _envelope(
        requestId: 'session_remove_timestamp',
        changeId: 'change_remove_time_003',
        baseRevision: controller.snapshot.revision,
        actions: [
          {'op': 'remove', 'id': medicine.id},
        ],
      ),
    );

    final appliedAt = DateTime(2026, 9, 17, 18, 45, 33);
    now = appliedAt;
    await controller.applyAi(plan, {0});

    final live = controller.snapshot.records[medicine.id]!;
    expect(live.archived, isTrue);
    expect(live.archiveReason, 'AI reviewed removal');
    expect(live.archivedAt, appliedAt.toUtc());
    expect(
      DateTime.parse(controller.snapshot.events.first['time'] as String).toUtc(),
      appliedAt.toUtc(),
    );
    expect(
      controller.snapshot.events.first['businessDay'],
      dateText(appliedAt),
    );
  });
}
