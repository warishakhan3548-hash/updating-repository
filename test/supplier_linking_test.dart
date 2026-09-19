import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/ai_protocol.dart';
import '../lib/domain/attention.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/supplier.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/services/supplier_return_service.dart';
import '../lib/ui/design.dart';
import '../lib/ui/supplier_screen.dart';

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

  test('supplier return projection is memoized per snapshot and civil day', () async {
    var now = today;
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => now,
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.saveSupplier(_supplierA, expectedRevision: 0);
    await controller.save(_stock('stock-a'), expectedRevision: 1);

    final first = controller.supplierReturns;
    expect(identical(first, controller.supplierReturns), isTrue);

    now = DateTime(2026, 9, 20);
    final nextDay = controller.supplierReturns;
    expect(identical(first, nextDay), isFalse);
    expect(identical(nextDay, controller.supplierReturns), isTrue);

    final live = controller.snapshot.records['stock-a']!;
    await controller.save(
      live.patch(<String, dynamic>{'quantity': 19}),
      expectedRevision: controller.snapshot.revision,
    );
    final afterWrite = controller.supplierReturns;
    expect(identical(nextDay, afterWrite), isFalse);
    expect(afterWrite.single.medicine.quantity, 19);
  });

  test('supplier return confirmation is skipped when sharing is dismissed', () {
    expect(
      SupplierReturnService.shouldOfferHandoverConfirmation(
        ShareResultStatus.dismissed,
      ),
      isFalse,
    );
    expect(
      SupplierReturnService.shouldOfferHandoverConfirmation(
        ShareResultStatus.success,
      ),
      isTrue,
    );
    expect(
      SupplierReturnService.shouldOfferHandoverConfirmation(
        ShareResultStatus.unavailable,
      ),
      isTrue,
    );
  });

  test('supplier return window is derived and reacts immediately to policy changes', () {
    final medicine = _stock('stock-a');
    final at45 = supplierReturnCandidates(
      medicines: <Medicine>[medicine],
      suppliers: <String, Supplier>{_supplierA.id: _supplierA},
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
      suppliers: <String, Supplier>{
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
      Supplier.fromJson(_supplierA.toJson()).drugLicenceNo,
      'DL-A-123',
    );
    expect(isReservedSupplierCustomFieldLabel('Drug licence no.'), isTrue);
    expect(isReservedSupplierCustomFieldLabel('State code'), isFalse);

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

  test('supplier return uses one authoritative instant across midnight', () async {
    final scripted = <DateTime>[];
    final fallback = DateTime(2026, 9, 19, 12);
    DateTime clock() => scripted.isEmpty ? fallback : scripted.removeAt(0);

    const supplier = Supplier(
      id: 'supplier_midnight',
      name: 'Midnight Pharma',
      returnBeforeExpiryDays: 0,
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: clock,
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.saveSupplier(supplier, expectedRevision: 0);
    await controller.save(
      _stock(
        'midnight-stock',
        supplierId: supplier.id,
        expiry: '2026-09-19',
      ),
      expectedRevision: 1,
    );
    final review = controller.reviewSupplierReturn(
      supplier.id,
      const <String>['midnight-stock'],
    );

    scripted.addAll(<DateTime>[
      DateTime(2026, 9, 19, 23, 59, 59),
      DateTime(2026, 9, 20, 0, 0, 1),
    ]);
    await controller.applySupplierReturn(review);

    final returned = controller.snapshot.records['midnight-stock']!;
    expect(dateText(returned.archivedAt!), '2026-09-19');
    expect(
      controller.snapshot.events.first['businessDay'],
      '2026-09-19',
    );
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

  testWidgets('supplier detail lazily builds a large linked stock list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const supplier = Supplier(
      id: 'supplier_large',
      name: 'Large Supplier',
      returnBeforeExpiryDays: 30,
    );
    final medicines = List<Medicine>.generate(
      240,
      (index) => Medicine(
        id: 'large-stock-$index',
        name: 'Medicine $index',
        strength: '500mg',
        form: 'Tablet',
        expiry: DateTime(2027, 12, 31),
        quantity: 10,
        supplierId: supplier.id,
      ),
      growable: false,
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          records: {for (final medicine in medicines) medicine.id: medicine},
          suppliers: <String, Supplier>{'supplier_large': supplier},
        ),
      ),
      clock: () => today,
      backgroundSearch: false,
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: SupplierDetailScreen(
          controller: controller,
          supplierId: supplier.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('All stock · 240'));
    await tester.pumpAndSettle();

    expect(find.text('Medicine 0 · 500mg'), findsOneWidget);
    // The old eager children list created all 240 cards at route-open time.
    // A far row now stays out of the element tree until scrolling reaches it.
    expect(find.text('Medicine 99 · 500mg'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Medicine 99 · 500mg'),
      700,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 40,
    );
    expect(find.text('Medicine 99 · 500mg'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test(
    'supplier integrity rejects missing links and allows atomic unlink + removal',
    () async {
      final missingSupplier = MemoryInventoryStorage();
      await expectLater(
        missingSupplier.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Invalid supplier link',
            upserts: <Medicine>[
              _stock('missing-link', supplierId: 'supplier_missing'),
            ],
          ),
        ),
        throwsFormatException,
      );
      expect((await missingSupplier.load()).revision, 0);

      final linked = _stock('linked-stock');
      final storage = MemoryInventoryStorage(
        InventorySnapshot(
          records: <String, Medicine>{linked.id: linked},
          suppliers: <String, Supplier>{_supplierA.id: _supplierA},
        ),
      );

      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Unsafe supplier removal',
            upserts: const <Medicine>[],
            removeSupplierIds: const <String>['supplier_a'],
          ),
        ),
        throwsFormatException,
      );
      expect((await storage.load()).revision, 0);

      final after = await storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Unlink stock and remove supplier',
          upserts: <Medicine>[
            linked.patch(<String, dynamic>{'supplierId': ''}),
          ],
          removeSupplierIds: const <String>['supplier_a'],
        ),
      );
      expect(after.revision, 1);
      expect(after.suppliers, isEmpty);
      expect(after.records['linked-stock']!.supplierId, isEmpty);
    },
  );

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
      suppliers: <String, Supplier>{_supplierA.id: _supplierA},
    );
    expect(plan.changes.single.after.supplierId, _supplierA.id);

    expect(
      () => parseAiPlan(
        request('unknown_supplier'),
        <String, Medicine>{live.id: live},
        1,
        const <String>{},
        today,
        suppliers: <String, Supplier>{_supplierA.id: _supplierA},
      ),
      throwsFormatException,
    );
  });
}
