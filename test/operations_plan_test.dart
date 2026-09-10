import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/operations_plan.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(String id, String name) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': '500mg',
  'form': 'Tablet',
  'expiry': '2027-01',
  'quantity': 10,
  'sold': false,
  'archived': false,
});

AttentionItem _item(
  String key,
  AttentionKind kind, {
  AttentionSeverity severity = AttentionSeverity.medium,
  List<String> stockIds = const <String>[],
  String? productKey,
}) => AttentionItem(
  key: key,
  kind: kind,
  severity: severity,
  title: key,
  detail: 'review $key',
  stockIds: stockIds,
  productKey: productKey,
);

void main() {
  group('pharmacist operations plan', () {
    test('unknown quantity becomes a prerequisite for same-product reorder', () {
      final dolo = _stock('dolo', 'Dolo');
      final plan = PharmacyOperationsPlan.build(
        medicines: [dolo],
        items: [
          _item(
            'quantity:dolo',
            AttentionKind.unknownQuantity,
            severity: AttentionSeverity.high,
            stockIds: [dolo.id],
          ),
          _item(
            'reorder:dolo',
            AttentionKind.urgentReorder,
            severity: AttentionSeverity.high,
            stockIds: [dolo.id],
            productKey: dolo.identity,
          ),
        ],
      );

      final reorder = plan.steps.singleWhere(
        (step) => step.item.key == 'reorder:dolo',
      );
      expect(reorder.blocked, isTrue);
      expect(reorder.prerequisites.single.key, 'quantity:dolo');
      expect(plan.nextStep?.item.key, 'quantity:dolo');
      expect(plan.blockedCount, 1);
    });

    test('verification on another product does not block a safe reorder', () {
      final dolo = _stock('dolo', 'Dolo');
      final crocin = _stock('crocin', 'Crocin');
      final plan = PharmacyOperationsPlan.build(
        medicines: [dolo, crocin],
        items: [
          _item(
            'quantity:crocin',
            AttentionKind.unknownQuantity,
            stockIds: [crocin.id],
          ),
          _item(
            'reorder:dolo',
            AttentionKind.reorderReview,
            stockIds: [dolo.id],
            productKey: dolo.identity,
          ),
        ],
      );

      final reorder = plan.steps.singleWhere(
        (step) => step.item.key == 'reorder:dolo',
      );
      expect(reorder.blocked, isFalse);
    });

    test('cross-identity barcode conflict blocks downstream work on either row', () {
      final dolo = _stock('dolo', 'Dolo');
      final crocin = _stock('crocin', 'Crocin');
      final plan = PharmacyOperationsPlan.build(
        medicines: [dolo, crocin],
        items: [
          _item(
            'barcode:123',
            AttentionKind.barcodeConflict,
            severity: AttentionSeverity.high,
            stockIds: [dolo.id, crocin.id],
          ),
          _item(
            'reorder:dolo',
            AttentionKind.urgentReorder,
            stockIds: [dolo.id],
            productKey: dolo.identity,
          ),
          _item(
            'reorder:crocin',
            AttentionKind.urgentReorder,
            stockIds: [crocin.id],
            productKey: crocin.identity,
          ),
        ],
      );

      for (final key in ['reorder:dolo', 'reorder:crocin']) {
        final step = plan.steps.singleWhere((candidate) => candidate.item.key == key);
        expect(step.prerequisites.map((item) => item.key), contains('barcode:123'));
      }
    });

    test('expired stock remains the first unblocked safety action', () {
      final dolo = _stock('dolo', 'Dolo');
      final plan = PharmacyOperationsPlan.build(
        medicines: [dolo],
        items: [
          _item(
            'reorder:dolo',
            AttentionKind.urgentReorder,
            severity: AttentionSeverity.high,
            stockIds: [dolo.id],
            productKey: dolo.identity,
          ),
          _item(
            'expired:dolo',
            AttentionKind.expiredStock,
            severity: AttentionSeverity.critical,
            stockIds: [dolo.id],
          ),
        ],
      );

      expect(plan.nextStep?.item.key, 'expired:dolo');
      expect(plan.nextStep?.lane, OperationsLane.safety);
    });
  });
}
