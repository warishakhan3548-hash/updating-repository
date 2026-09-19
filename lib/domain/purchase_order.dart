import 'medicine.dart';

class PurchaseOrderLine {
  const PurchaseOrderLine({
    required this.name,
    required this.salt,
    required this.strength,
    required this.reason,
    required this.quantity,
    this.currentQuantity,
    this.unitCostPaise,
  });

  final String name;
  final String salt;
  final String strength;
  final String reason;
  final int quantity;
  final int? currentQuantity;
  final int? unitCostPaise;

  int? get estimatedAmountPaise =>
      unitCostPaise == null ? null : stockValue(quantity, unitCostPaise!);

  Map<String, dynamic> toJson() => {
    'name': name,
    'salt': salt,
    'strength': strength,
    'reason': reason,
    'quantity': quantity,
    'currentQuantity': currentQuantity,
    'unitCostPaise': unitCostPaise,
    'estimatedAmountPaise': estimatedAmountPaise,
  };
}

/// Validates and canonicalizes a purchase order before it reaches PDF/share
/// integration. The guard is deliberately deterministic: it validates only
/// operational facts already chosen by the pharmacist and never invents an
/// order quantity, price, salt, strength or medicine identity.
List<PurchaseOrderLine> validatePurchaseOrderDraft(
  Iterable<PurchaseOrderLine> source,
) {
  final input = source.toList(growable: false);
  if (input.isEmpty) {
    throw const FormatException('Select at least one medicine to order.');
  }
  if (input.length > 500) {
    throw const FormatException(
      'A single purchase order can contain at most 500 medicine lines.',
    );
  }

  final result = <PurchaseOrderLine>[];
  final identities = <String>{};
  var estimatedTotalPaise = 0;

  for (var index = 0; index < input.length; index++) {
    final line = input[index];
    final lineNumber = index + 1;
    final name = _cleanRequired(
      line.name,
      field: 'medicine name',
      line: lineNumber,
      max: 240,
    );
    final salt = _cleanOptional(
      line.salt,
      field: 'salt',
      line: lineNumber,
      max: 320,
    );
    final strength = _cleanOptional(
      line.strength,
      field: 'strength',
      line: lineNumber,
      max: 120,
    );
    final reason = _cleanRequired(
      line.reason,
      field: 'reason',
      line: lineNumber,
      max: 600,
    );

    if (line.quantity < 1 || line.quantity > 100000000) {
      throw FormatException(
        'Purchase-order line $lineNumber has an invalid quantity.',
      );
    }
    final current = line.currentQuantity;
    if (current != null && (current < 0 || current > 100000000)) {
      throw FormatException(
        'Purchase-order line $lineNumber has an invalid current quantity.',
      );
    }
    final cost = line.unitCostPaise;
    if (cost != null && (cost < 0 || cost > maxExactPaise)) {
      throw FormatException(
        'Purchase-order line $lineNumber has an invalid unit cost.',
      );
    }

    // Do not silently merge or double-order duplicate medicine lines. Salt is
    // included when known; an unknown salt stays unknown rather than being
    // treated as equal to a different known formulation.
    final identity = <String>[
      normalize(name),
      identityPart(strength),
      normalize(salt),
    ].join('|');
    if (!identities.add(identity)) {
      throw FormatException(
        'Purchase order contains the same medicine line more than once. Review duplicate quantities instead of combining them automatically.',
      );
    }

    final canonical = PurchaseOrderLine(
      name: name,
      salt: salt,
      strength: strength,
      reason: reason,
      quantity: line.quantity,
      currentQuantity: current,
      unitCostPaise: cost,
    );
    final amount = canonical.estimatedAmountPaise;
    if (amount != null) {
      if (amount > maxExactPaise - estimatedTotalPaise) {
        throw const FormatException(
          'Estimated purchase-order total is too large to represent safely.',
        );
      }
      estimatedTotalPaise += amount;
    }
    result.add(canonical);
  }

  return List.unmodifiable(result);
}

String _cleanRequired(
  String value, {
  required String field,
  required int line,
  required int max,
}) {
  final clean = value.trim();
  if (clean.isEmpty || clean.length > max || _hasUnsafeControl(clean)) {
    throw FormatException('Purchase-order line $line has an invalid $field.');
  }
  return clean;
}

String _cleanOptional(
  String value, {
  required String field,
  required int line,
  required int max,
}) {
  final clean = value.trim();
  if (clean.length > max || _hasUnsafeControl(clean)) {
    throw FormatException('Purchase-order line $line has an invalid $field.');
  }
  return clean;
}

bool _hasUnsafeControl(String value) => value.runes.any(
  (rune) => rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D,
);
