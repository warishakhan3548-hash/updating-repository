import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/operations_plan.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(
  String id, {
  String expiry = '2026-09-15',
  int? quantity = 10,
  String block = '',
  String row = '',
  String vertical = '',
  String location = '',
  bool sold = false,
}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'form': 'Tablet',
  'quantity': sold ? 0 : quantity,
  'expiry': expiry,
  'block': block,
  'row': row,
  'vertical': vertical,
  'location': location,
  'sold': sold,
  'soldAt': sold ? '2026-09-09T10:00:00.000' : null,
  'soldQuantity': sold ? 10 : null,
  'revision': 1,
});

void main() {
  final today = DateTime(2026, 9, 10);
  const settings = WarningSettings(shortDays: 8, months: 2);

  group('physical stock findability intelligence', () {
    test('active physical stock without a location is surfaced locally', () {
      final medicine = stock('missing');
      final report = PharmacyAttentionReport.build(
        medicines: [medicine],
        settings: settings,
        today: today,
        reorder: const [],
      );

      final item = report.items.singleWhere(
        (item) => item.kind == AttentionKind.missingStockLocation,
      );
      expect(item.stockIds, ['missing']);
      expect(item.productKey, medicine.identity);
      expect(item.severity, AttentionSeverity.high);
      expect(
        item.detail,
        contains('no Block, Row, Vertical or shelf location'),
      );
    });

    test(
      'findability does not create noise for sold, zero or located stock',
      () {
        final report = PharmacyAttentionReport.build(
          medicines: [
            stock('sold', sold: true),
            stock('zero', quantity: 0),
            stock('located', block: 'B1', row: 'R2'),
          ],
          settings: settings,
          today: today,
          reorder: const [],
        );

        expect(
          report.items.where(
            (item) => item.kind == AttentionKind.missingStockLocation,
          ),
          isEmpty,
        );
      },
    );

    test('missing location is sequenced before physical short-expiry work', () {
      final medicine = stock('near-expiry');
      final report = PharmacyAttentionReport.build(
        medicines: [medicine],
        settings: settings,
        today: today,
        reorder: const [],
      );
      final plan = PharmacyOperationsPlan.build(
        items: report.items,
        medicines: [medicine],
      );

      final findability = plan.steps.singleWhere(
        (step) => step.item.kind == AttentionKind.missingStockLocation,
      );
      final expiry = plan.steps.singleWhere(
        (step) => step.item.kind == AttentionKind.shortExpiry,
      );
      expect(findability.blocked, isFalse);
      expect(findability.lane, OperationsLane.location);
      expect(expiry.blocked, isTrue);
      expect(
        expiry.prerequisites.map((item) => item.kind),
        contains(AttentionKind.missingStockLocation),
      );
      expect(plan.nextStep?.item.kind, AttentionKind.missingStockLocation);
    });

    test(
      'missing location never blocks a valid purchasing review by itself',
      () {
        final medicine = stock('stock-a', expiry: '2027-12', quantity: 3);
        final items = <AttentionItem>[
          AttentionItem(
            key: 'location-missing:${medicine.id}',
            kind: AttentionKind.missingStockLocation,
            severity: AttentionSeverity.medium,
            title: 'Location missing',
            detail: 'Record physical location.',
            stockIds: [medicine.id],
            productKey: medicine.identity,
          ),
          AttentionItem(
            key: 'reorder:${medicine.identity}',
            kind: AttentionKind.reorderReview,
            severity: AttentionSeverity.medium,
            title: 'Reorder review',
            detail: 'Review stock order.',
            stockIds: [medicine.id],
            productKey: medicine.identity,
          ),
        ];

        final plan = PharmacyOperationsPlan.build(
          items: items,
          medicines: [medicine],
        );
        final reorder = plan.steps.singleWhere(
          (step) => step.item.kind == AttentionKind.reorderReview,
        );
        expect(reorder.blocked, isFalse);
        expect(reorder.prerequisites, isEmpty);
      },
    );
  });
}
