import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/ai_protocol.dart';
import '../lib/domain/attention.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/supplier.dart';
import '../lib/state/pharmacy_controller.dart';

const _supplierA = Supplier(
  id: 'supplier_a',
  name: 'ABC Pharma',
  returnBeforeExpiryDays: 45,
  address: 'Panipat',
  gstin: '06ABCDE1234F1Z5',
  drugLicenceNo: 'DL-A-123',
);

const _supplierB = Supplier(
  id: 'supplier_b',
  name: 'XYZ Pharma',
  returnBeforeExpiryDays: 30,
);

Medicine _stock(
  String id, {
  String supplierId = 'supplier_a',
  String expiry = '2026-11-03',
  int? quantity = 20,
  String batch = 'LOT-A52',
}) => Medicine.fromJson(<String, dynamic>{
  'id': id,
  'name': 'Amoxicillin',
  'strength': '500mg',
  'form': 'Tablet',
  'expiry': expiry,
  'quantity': quantity,
  'batchNumber': batch,
  'barcode': '8901234567890',
  'location': 'Rack A',
  'supplierId': supplierId,
});

void main() {
  final today = DateTime(2026, 9, 19);

  test('supplier return window is derived and reacts immediately to policy changes', () {
    final medicine = _stock('stock-a');
    final at45 = supplierReturnCandidates(
      medicines: <Medicine>[medicine],
      suppliers: const <String, Supplier>{_supplierA.id: _supplierA},
      today: today,
    );
    expect(at45.single.medicine.id, medicine.id);
    expect(at45.single.daysLeft, 45);

    final stricter = _supplierA.patch(<String, dynamic>{
      'returnBeforeExpiryDays': 44,
    });
    final at44 = supplierReturnCandidates(
      medicines: <Medicine>[medicine],
      suppliers: <String, Supplier>{stricter.id: stricter},
      today: today,
    );
    expect(at44, isEmpty);
  });

  test('same medicine and batch can stay linked to different exact suppliers', () {
    final first = _stock('stock-a', supplierId: _supplierA.id);
    final second = _stock('stock-b', supplierId: _supplierB.id);

    final candidates = supplierReturnCandidates(
      medicines: <Medicine>[first, second],
      suppliers: const <String, Supplier>{
        _supplierA.id: _supplierA,
        _supplierB.id: _supplierB,
      },
      today: today,
    );

    expect(
      candidates.map((item) => item.medicine.id).toSet(),
      <String>{first.id},
    );

    final attention = PharmacyAttentionReport.build(
      medicines: <Medicine>[first, second],
      settings: const WarningSettings(shortDays: 3, months: 1),
      today: today,
      reorder: const [],
    );
    expect(
      attention.items
          .where((item) => item.kind == AttentionKind.possibleDuplicateBatch),
      isEmpty,
    );
  });

  test('custom supplier fields stay flexible but cannot duplicate core stock facts', () {
    final supplier = Supplier.fromJson(<String, dynamic>{
      'id': 'supplier_custom',
      'name': 'Universal Distributor',
      'returnBeforeExpiryDays': 30,
      'address': '',
      'gstin': '',
      'drugLicenceNo': '',
      'customFields': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'field_state_01',
          'label': 'State Code',
          'value': '06',
        },
      ],
      'revision': 1,
    });
    expect(supplier.customFields.single.label, 'State Code');
    expect(_supplierA.drugLicenceNo, 'DL-A-123');

    expect(
      () => Supplier.fromJson(<String, dynamic>{
        'id': 'supplier_bad',
        'name': 'Bad Duplicate',
        'returnBeforeExpiryDays': 30,
        'address': '',
        'gstin': '',
        'drugLicenceNo': '',
        'customFields': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'field_batch_01',
            'label': 'Batch Number',
            'value': 'A52',
          },
        ],
        'revision': 1,
      }),
      throwsFormatException,
    );
  });

  test('reviewed supplier return archives exact rows and stays undoable', () async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => today,
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.saveSupplier(_supplierA, expectedRevision: 0);
    await controller.save(_stock('stock-a'), expectedRevision: 1);

    expect(controller.supplierReturns.single.medicine.id, 'stock-a');
    final review = controller.reviewSupplierReturn(
      _supplierA.id,
      const <String>['stock-a'],
    );
    expect(review.totalUnits, 20);

    await controller.applySupplierReturn(review);
    final returned = controller.snapshot.records['stock-a']!;
    expect(returned.archived, isTrue);
    expect(returned.archiveReason, 'Returned to ABC Pharma');
    expect(controller.supplierReturns, isEmpty);

    expect(controller.canUndo, isTrue);
    await controller.undo();
    expect(controller.snapshot.records['stock-a']!.archived, isFalse);
    expect(controller.snapshot.records['stock-a']!.supplierId, _supplierA.id);
  });

  test('supplier return review fails closed after the stock row changes', () async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => today,
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.saveSupplier(_supplierA, expectedRevision: 0);
    await controller.save(_stock('stock-a'), expectedRevision: 1);
    final review = controller.reviewSupplierReturn(
      _supplierA.id,
      const <String>['stock-a'],
    );

    final live = controller.snapshot.records['stock-a']!;
    await controller.save(
      live.patch(<String, dynamic>{'quantity': 19}),
      expectedRevision: controller.snapshot.revision,
    );

    await expectLater(
      controller.applySupplierReturn(review),
      throwsStateError,
    );
    expect(controller.snapshot.records['stock-a']!.archived, isFalse);
  });

  test('external AI may link only an existing supplier ID', () {
    const requestId = 'supplier_ai_session';
    String request(String supplierId) => jsonEncode(<String, dynamic>{
      'schema': pharmacySchema,
      'requestId': requestId,
      'changeId': 'change_link_001',
      'baseRevision': 1,
      'reply': 'Prepared for review',
      'actions': <Map<String, dynamic>>[
        <String, dynamic>{
          'op': 'update',
          'id': 'stock-a',
          'fields': <String, dynamic>{'supplierId': supplierId},
        },
      ],
    });

    final live = _stock('stock-a', supplierId: '');
    final plan = parseAiPlan(
      request(_supplierA.id),
      <String, Medicine>{live.id: live},
      1,
      const <String>{},
      today,
      suppliers: const <String, Supplier>{_supplierA.id: _supplierA},
    );
    expect(plan.changes.single.after.supplierId, _supplierA.id);

    expect(
      () => parseAiPlan(
        request('unknown_supplier'),
        <String, Medicine>{live.id: live},
        1,
        const <String>{},
        today,
        suppliers: const <String, Supplier>{_supplierA.id: _supplierA},
      ),
      throwsFormatException,
    );
  });
}
