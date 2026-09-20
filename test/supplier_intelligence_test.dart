import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/supplier.dart';
import 'package:aaris_pharmacy/domain/supplier_intelligence.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Supplier _supplier(
  String id,
  String name, {
  int returnDays = 30,
  int? leadDays,
}) => Supplier.fromJson(<String, dynamic>{
  'id': id,
  'name': name,
  'returnBeforeExpiryDays': returnDays,
  'customFields': <Map<String, dynamic>>[
    if (leadDays != null)
      <String, dynamic>{
        'id': 'lead_field_${id}',
        'label': 'Lead time days',
        'value': '$leadDays days',
      },
  ],
});

Map<String, dynamic> _intake({
  required String productKey,
  required String supplierId,
  required String receivedAt,
  required String expiry,
  int cost = 500,
  String batch = '',
}) => <String, dynamic>{
  'productKey': productKey,
  'supplierId': supplierId,
  'quantity': 20,
  'receivedAt': receivedAt,
  'expiry': expiry,
  'source': 'receive',
  'unitCostPaise': cost,
  'batchNumber': batch,
};

void main() {
  final today = DateTime(2026, 9, 20);

  test('supplier lead-time uses one unambiguous existing custom field', () {
    final supplier = _supplier('supplier_a', 'A Pharma', leadDays: 12);
    expect(supplierPlanningLeadDays(supplier), 12);

    final conflicting = Supplier.fromJson(<String, dynamic>{
      ...supplier.toJson(),
      'customFields': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'lead_time_01',
          'label': 'Lead time',
          'value': '12 days',
        },
        <String, dynamic>{
          'id': 'delivery_01',
          'label': 'Delivery days',
          'value': '5 days',
        },
      ],
    });
    expect(supplierPlanningLeadDays(conflicting), isNull);
  });

  test('reorder planning uses linked supplier lead-time instead of fixed 7 days', () {
    final supplier = _supplier('supplier_a', 'A Pharma', leadDays: 14);
    final stock = Medicine.fromJson(<String, dynamic>{
      'id': 'stock_lead',
      'name': 'Cefixime',
      'strength': '200mg',
      'form': 'Tablet',
      'expiry': '2027-12',
      'quantity': 0,
      'supplierId': supplier.id,
    });
    final tracking = TrackingStats(
      medicines: <Medicine>[stock],
      sales: const <SaleEvent>[],
      range: TrackingRange.lastDays(today, 30),
      today: today,
      suppliers: <String, Supplier>{supplier.id: supplier},
    );

    expect(tracking.reorder, hasLength(1));
    expect(tracking.reorder.single.planningLeadDays, 14);
  });

  test('supplier advice learns per medicine and abstains until evidence is repeated', () {
    final supplierA = _supplier('supplier_a', 'A Pharma', returnDays: 30, leadDays: 3);
    final supplierB = _supplier('supplier_b', 'B Pharma', returnDays: 10, leadDays: 7);
    final productKey = medicineIdentity('Cefixime', '200mg', 'Tablet');
    Medicine observed(
      String id,
      String supplierId,
      List<Map<String, dynamic>> history,
    ) => Medicine.fromJson(<String, dynamic>{
      'id': id,
      'name': 'Cefixime',
      'strength': '200mg',
      'form': 'Tablet',
      'expiry': '2028-12',
      'quantity': 10,
      'supplierId': supplierId,
      'intakeHistory': history,
    });

    final a = observed('stock_a', supplierA.id, <Map<String, dynamic>>[
      _intake(
        productKey: productKey,
        supplierId: supplierA.id,
        receivedAt: '2026-01-10T09:00:00Z',
        expiry: '2028-01-31',
        batch: 'A1',
      ),
      _intake(
        productKey: productKey,
        supplierId: supplierA.id,
        receivedAt: '2026-03-10T09:00:00Z',
        expiry: '2028-03-31',
        batch: 'A2',
      ),
    ]);
    final bOne = observed('stock_b1', supplierB.id, <Map<String, dynamic>>[
      _intake(
        productKey: productKey,
        supplierId: supplierB.id,
        receivedAt: '2026-01-10T09:00:00Z',
        expiry: '2026-12-31',
        batch: 'B1',
      ),
    ]);
    final reorder = <ReorderSuggestion>[
      ReorderSuggestion(
        productKey: productKey,
        name: 'Cefixime',
        salt: '',
        strength: '200mg',
        form: 'Tablet',
        priority: ReorderPriority.soon,
        reason: 'Low stock',
        suggestedQuantity: 20,
        unitsSold: 30,
        unitsPerDay: 1,
        stockIds: const <String>['stock_a'],
      ),
    ];

    expect(
      buildSupplierPurchaseAdvice(
        medicines: <Medicine>[a, bOne],
        suppliers: <String, Supplier>{
          supplierA.id: supplierA,
          supplierB.id: supplierB,
        },
        reorder: reorder,
        today: today,
      ),
      isEmpty,
    );

    final bTwo = observed('stock_b2', supplierB.id, <Map<String, dynamic>>[
      _intake(
        productKey: productKey,
        supplierId: supplierB.id,
        receivedAt: '2026-03-10T09:00:00Z',
        expiry: '2027-02-28',
        batch: 'B2',
      ),
    ]);
    final advice = buildSupplierPurchaseAdvice(
      medicines: <Medicine>[a, bOne, bTwo],
      suppliers: <String, Supplier>{
        supplierA.id: supplierA,
        supplierB.id: supplierB,
      },
      reorder: reorder,
      today: today,
    );

    expect(advice[productKey]?.supplierId, supplierA.id);
    expect(advice[productKey]?.reason, contains('usable shelf-life'));
  });

  test('receive evidence is atomic with stock and Undo restores prior learning', () async {
    final supplier = _supplier('supplier_a', 'A Pharma');
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => today,
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.saveSupplier(supplier, expectedRevision: 0);
    await controller.save(
      Medicine.fromJson(<String, dynamic>{
        'id': 'lot_1',
        'name': 'Cefixime',
        'strength': '200mg',
        'form': 'Tablet',
        'expiry': '2028-12',
        'quantity': 10,
        'supplierId': supplier.id,
        'batchNumber': 'LOT-1',
      }),
      expectedRevision: 1,
    );

    expect(controller.snapshot.records['lot_1']!.intakeHistory, hasLength(1));
    final review = controller.reviewStockAdjustment(
      'lot_1',
      kind: StockAdjustmentKind.receive,
      quantity: 5,
    );
    await controller.applyStockAdjustment(review);
    expect(controller.snapshot.records['lot_1']!.quantity, 15);
    expect(controller.snapshot.records['lot_1']!.intakeHistory, hasLength(2));
    expect(controller.snapshot.records['lot_1']!.intakeHistory.last.source, 'receive');

    await controller.undo();
    expect(controller.snapshot.records['lot_1']!.quantity, 10);
    expect(controller.snapshot.records['lot_1']!.intakeHistory, hasLength(1));
  });

  test('missing supplier is surfaced only when return planning is relevant', () {
    Medicine stock(String id, String expiry) => Medicine.fromJson(<String, dynamic>{
      'id': id,
      'name': 'Paracetamol',
      'strength': '500mg',
      'form': 'Tablet',
      'expiry': expiry,
      'quantity': 20,
      'location': 'Rack A',
    });
    final report = PharmacyAttentionReport.build(
      medicines: <Medicine>[
        stock('near', '2026-10-10'),
        stock('far', '2027-12-31'),
      ],
      settings: const WarningSettings(shortDays: 8, months: 2),
      today: today,
      reorder: const <ReorderSuggestion>[],
    );
    final missing = report.items
        .where((item) => item.kind == AttentionKind.missingSupplierLink)
        .toList(growable: false);
    expect(missing, hasLength(1));
    expect(missing.single.stockIds, const <String>['near']);
  });
}
