import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/operations_plan.dart';
import 'package:aaris_pharmacy/domain/sale_history_integrity.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock({
  required String id,
  String name = 'Dolo',
  String strength = '650mg',
  String mfg = '2026-01-01',
  String expiry = '2027-01-01',
  int quantity = 20,
  bool archived = false,
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'form': 'Tablet',
  'salt': 'Paracetamol',
  'mfg': mfg,
  'expiry': expiry,
  'quantity': quantity,
  'location': 'Shelf A1',
  'archived': archived,
});

SaleEvent _sale(
  String id,
  String stockId,
  DateTime occurredAt, {
  String name = 'Dolo',
  String strength = '650mg',
}) => SaleEvent(
  id: id,
  stockId: stockId,
  medicineName: name,
  strength: strength,
  form: 'Tablet',
  salt: 'Paracetamol',
  quantity: 1,
  occurredAt: occurredAt,
);

void main() {
  final today = DateTime(2026, 9, 10, 18, 30);

  group('sale-history integrity auditor', () {
    test('groups future-dated recovered sales without mutating history', () {
      final stock = _stock(id: 'future-stock');
      final sales = <SaleEvent>[
        _sale('sale-1', stock.id, DateTime(2026, 9, 11, 9)),
        _sale('sale-2', stock.id, DateTime(2026, 9, 12, 11)),
      ];

      final report = SaleHistoryIntegrityReport.build(
        medicines: [stock],
        sales: sales,
        today: today,
      );

      expect(report.issues, hasLength(1));
      final issue = report.issues.single;
      expect(issue.kind, SaleHistoryIntegrityKind.futureSaleEvent);
      expect(issue.stockIds, ['future-stock']);
      expect(issue.detail, contains('2 recorded sale events'));
      expect(issue.detail, contains('2026-09-11'));
      expect(sales, hasLength(2));
    });

    test('groups before-MFG and after-EXP chronology conflicts', () {
      final stock = _stock(
        id: 'chronology-stock',
        mfg: '2026-03-01',
        expiry: '2026-08-31',
      );

      final report = SaleHistoryIntegrityReport.build(
        medicines: [stock],
        sales: [
          _sale('before-mfg', stock.id, DateTime(2026, 2, 28)),
          _sale('after-exp', stock.id, DateTime(2026, 9, 1)),
        ],
        today: today,
      );

      expect(report.issues, hasLength(1));
      final issue = report.issues.single;
      expect(issue.kind, SaleHistoryIntegrityKind.lifecycleConflict);
      expect(issue.detail, contains('before recorded MFG 2026-03-01'));
      expect(issue.detail, contains('after recorded EXP 2026-08-31'));
    });

    test('does not project corrected current identity facts onto old sales', () {
      final corrected = _stock(
        id: 'corrected',
        name: 'Crocin',
        strength: '500mg',
        mfg: '2026-09-05',
        expiry: '2027-09-01',
      );

      final report = SaleHistoryIntegrityReport.build(
        medicines: [corrected],
        sales: [
          _sale('historic-dolo', corrected.id, DateTime(2026, 8, 1)),
        ],
        today: today,
      );

      expect(report.isEmpty, isTrue);
    });

    test('removed stock is not turned into an unactionable active task', () {
      final archived = _stock(id: 'removed', archived: true);
      final report = SaleHistoryIntegrityReport.build(
        medicines: [archived],
        sales: [
          _sale('future-on-removed', archived.id, DateTime(2026, 9, 12)),
        ],
        today: today,
      );

      expect(report.isEmpty, isTrue);
    });
  });

  test('chronology verification blocks related reorder until reviewed', () {
    final stock = _stock(
      id: 'reorder-stock',
      mfg: '2026-09-05',
      expiry: '2027-06-30',
    );
    final sale = _sale('legacy-sale', stock.id, DateTime(2026, 9, 4));
    final reorder = ReorderSuggestion(
      productKey: stock.identity,
      name: stock.name,
      salt: stock.salt,
      strength: stock.strength,
      form: stock.form,
      priority: ReorderPriority.urgent,
      reason: 'Recorded demand requires review',
      suggestedQuantity: 10,
      unitsSold: 8,
      unitsPerDay: 1,
      stockIds: [stock.id],
      confidence: .9,
      reviewRequired: false,
    );

    final attention = PharmacyAttentionReport.build(
      medicines: [stock],
      settings: const WarningSettings(),
      today: today,
      reorder: [reorder],
      sales: [sale],
    );
    final chronology = attention.items.singleWhere(
      (item) => item.kind == AttentionKind.saleLifecycleConflict,
    );
    expect(chronology.severity, AttentionSeverity.high);

    final plan = PharmacyOperationsPlan.build(
      items: attention.items,
      medicines: [stock],
    );
    final reorderStep = plan.steps.singleWhere((step) => step.item.isReorder);
    expect(reorderStep.blocked, isTrue);
    expect(
      reorderStep.prerequisites.map((item) => item.kind),
      contains(AttentionKind.saleLifecycleConflict),
    );
    expect(
      plan.steps.indexWhere(
        (step) => step.item.kind == AttentionKind.saleLifecycleConflict,
      ),
      lessThan(plan.steps.indexOf(reorderStep)),
    );
  });
}
