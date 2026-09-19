import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/purchase_order.dart';
import 'package:flutter_test/flutter_test.dart';

PurchaseOrderLine _line({
  String name = 'Dolo',
  String salt = 'Paracetamol',
  String strength = '650mg',
  String reason = 'Low stock',
  int quantity = 20,
  int? currentQuantity = 4,
  int? unitCostPaise = 250,
}) => PurchaseOrderLine(
  name: name,
  salt: salt,
  strength: strength,
  reason: reason,
  quantity: quantity,
  currentQuantity: currentQuantity,
  unitCostPaise: unitCostPaise,
);

void main() {
  group('purchase-order guard', () {
    test('canonicalizes reviewed text without inventing order facts', () {
      final result = validatePurchaseOrderDraft([
        _line(
          name: '  Dolo  ',
          salt: ' Paracetamol ',
          strength: ' 650mg ',
          reason: ' Low stock ',
        ),
      ]);

      expect(result, hasLength(1));
      expect(result.single.name, 'Dolo');
      expect(result.single.salt, 'Paracetamol');
      expect(result.single.strength, '650mg');
      expect(result.single.reason, 'Low stock');
      expect(result.single.quantity, 20);
      expect(() => result.add(_line(name: 'Crocin')), throwsUnsupportedError);
    });

    test('rejects duplicate medicine lines instead of double ordering', () {
      expect(
        () => validatePurchaseOrderDraft([
          _line(),
          _line(reason: 'Urgent reorder', quantity: 10),
        ]),
        throwsFormatException,
      );
    });

    test('rejects invalid quantity and unsafe control text', () {
      expect(
        () => validatePurchaseOrderDraft([_line(quantity: 0)]),
        throwsFormatException,
      );
      expect(
        () => validatePurchaseOrderDraft([_line(reason: 'Low\u0000stock')]),
        throwsFormatException,
      );
    });

    test('fails closed when an estimated order amount cannot be represented', () {
      expect(
        () => validatePurchaseOrderDraft([
          _line(quantity: 2, unitCostPaise: maxExactPaise),
        ]),
        throwsA(anything),
      );
    });
  });
}
