import 'inventory.dart';
import 'medicine.dart';
import 'tracking.dart';

/// A deterministic persistence-boundary reason why an attempted sale-ledger
/// mutation must fail closed.
///
/// Sale events are operational audit facts. They are not a second stock source
/// of truth, but once written they must remain append-only outside the existing
/// reviewed Undo/backup recovery paths. Keeping this policy in the domain layer
/// means UI, Aaris Brain, local AI and future callers all receive the same guard.
class SaleLedgerMutationBlock {
  const SaleLedgerMutationBlock({
    required this.message,
    this.saleIds = const <String>[],
    this.stockIds = const <String>[],
  });

  final String message;
  final List<String> saleIds;
  final List<String> stockIds;
}

bool _sameSale(SaleEvent a, SaleEvent b) =>
    a.id == b.id &&
    a.stockId == b.stockId &&
    a.medicineName == b.medicineName &&
    a.strength == b.strength &&
    a.form == b.form &&
    a.salt == b.salt &&
    a.quantity == b.quantity &&
    a.occurredAt.isAtSameMomentAs(b.occurredAt) &&
    a.totalAmountPaise == b.totalAmountPaise &&
    a.savedUnitPricePaise == b.savedUnitPricePaise;

String _stockLabel(Medicine medicine) {
  final parts = <String>[
    medicine.title,
    if (medicine.batchNumber.trim().isNotEmpty)
      'batch ${medicine.batchNumber.trim()}',
    if (medicine.address.trim().isNotEmpty) medicine.address.trim(),
  ];
  return parts.join(' · ');
}

/// Validates an ordinary transaction that proposes new sale events.
///
/// The guard deliberately compares every newly appended sale against the
/// *pre-transaction* medicine row, then reconciles the total sold units against
/// the *post-transaction* row. That makes the stock delta and the immutable sale
/// audit one atomic invariant instead of trusting whichever caller constructed
/// [upsertSales].
///
/// Recovery transactions are intentionally handled by the storage layer and do
/// not call this function: Undo must restore the exact immediately previous
/// state, while an explicitly reviewed backup restore must reproduce its source
/// snapshot even when that snapshot contains legacy data that Needs Attention
/// may later surface for human review.
SaleLedgerMutationBlock? saleLedgerMutationBlock({
  required Map<String, Medicine> beforeRecords,
  required Map<String, Medicine> afterRecords,
  required Map<String, SaleEvent> beforeSales,
  required Iterable<SaleEvent> upsertSales,
  required Iterable<String> removeSaleIds,
  required DateTime now,
}) {
  final removed = removeSaleIds.toList(growable: false);
  if (removed.isNotEmpty) {
    return SaleLedgerMutationBlock(
      message:
          'Aaris blocked this transaction because ordinary app actions may not delete recorded sale history. Use the existing audited Undo or reviewed backup recovery flow instead. Nothing was changed.',
      saleIds: List.unmodifiable(removed),
    );
  }

  final additions = <SaleEvent>[];
  for (final sale in upsertSales) {
    final existing = beforeSales[sale.id];
    if (existing == null) {
      additions.add(sale);
      continue;
    }
    if (!_sameSale(existing, sale)) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this transaction because an existing sale audit event cannot be rewritten by an ordinary stock action. Use the reviewed recovery/history workflow instead. Nothing was changed.',
        saleIds: List.unmodifiable(<String>[sale.id]),
        stockIds: List.unmodifiable(<String>[sale.stockId]),
      );
    }
  }
  if (additions.isEmpty) return null;

  final today = civilDay(now);
  final byStock = <String, List<SaleEvent>>{};
  for (final sale in additions) {
    if (civilDay(sale.occurredAt).isAfter(today)) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this sale because its date is in the future. Verify the sale date before saving; nothing was changed.',
        saleIds: List.unmodifiable(<String>[sale.id]),
        stockIds: List.unmodifiable(<String>[sale.stockId]),
      );
    }

    final before = beforeRecords[sale.stockId];
    if (before == null) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this sale because its stock ID does not point to a medicine that existed before the transaction. Select an exact current stock entry instead of creating sale history for an unknown row. Nothing was changed.',
        saleIds: List.unmodifiable(<String>[sale.id]),
        stockIds: List.unmodifiable(<String>[sale.stockId]),
      );
    }
    if (before.archived || before.sold) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this sale because ${_stockLabel(before)} was already ${before.archived ? 'removed' : 'SOLD'} before the transaction. Restore/restock it through the existing reviewed workflow first. Nothing was changed.',
        saleIds: List.unmodifiable(<String>[sale.id]),
        stockIds: List.unmodifiable(<String>[sale.stockId]),
      );
    }

    // A new audit event may snapshot only identity facts that were already on
    // the authoritative stock row. This prevents a custom/AI caller from
    // inventing a different medicine or salt inside sales analytics.
    if (sale.productKey != before.identity ||
        normalize(sale.salt) != normalize(before.salt)) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this sale because its medicine snapshot does not match the exact authoritative stock entry. Reopen the medicine and record the sale from that row; nothing was changed.',
        saleIds: List.unmodifiable(<String>[sale.id]),
        stockIds: List.unmodifiable(<String>[sale.stockId]),
      );
    }

    try {
      validateDispensingDate(before, sale.occurredAt);
    } on FormatException catch (error) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this sale because the recorded sale date conflicts with the stock lifecycle: ${error.message} Nothing was changed.',
        saleIds: List.unmodifiable(<String>[sale.id]),
        stockIds: List.unmodifiable(<String>[sale.stockId]),
      );
    }

    byStock.putIfAbsent(sale.stockId, () => <SaleEvent>[]).add(sale);
  }

  for (final entry in byStock.entries) {
    final before = beforeRecords[entry.key]!;
    final after = afterRecords[entry.key];
    final saleIds = entry.value.map((sale) => sale.id).toList(growable: false);
    if (after == null || after.archived) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this transaction because a sale and removal of the same stock row were combined. Record the sale first, then review any separate removal action. Nothing was changed.',
        saleIds: List.unmodifiable(saleIds),
        stockIds: List.unmodifiable(<String>[entry.key]),
      );
    }

    if (after.identity != before.identity ||
        normalize(after.salt) != normalize(before.salt)) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this transaction because medicine identity facts changed in the same transaction as a sale. Save the verified medicine correction separately, then record the sale from the exact row. Nothing was changed.',
        saleIds: List.unmodifiable(saleIds),
        stockIds: List.unmodifiable(<String>[entry.key]),
      );
    }

    var soldUnits = 0;
    for (final sale in entry.value) {
      soldUnits += sale.quantity;
      if (soldUnits > 100000000) {
        return SaleLedgerMutationBlock(
          message:
              'Aaris blocked this transaction because the combined sale quantity is outside the supported stock range. Nothing was changed.',
          saleIds: List.unmodifiable(saleIds),
          stockIds: List.unmodifiable(<String>[entry.key]),
        );
      }
    }

    final beforeQuantity = before.quantity;
    if (beforeQuantity == null) {
      if (after.quantity != null || after.sold) {
        return SaleLedgerMutationBlock(
          message:
              'Aaris blocked this transaction because the starting stock quantity for ${_stockLabel(before)} is unknown. A sale may be recorded against unknown stock, but it cannot simultaneously invent a remaining quantity or silently mark the row SOLD. Verify the physical count separately. Nothing was changed.',
          saleIds: List.unmodifiable(saleIds),
          stockIds: List.unmodifiable(<String>[entry.key]),
        );
      }
      continue;
    }

    if (soldUnits > beforeQuantity) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this transaction because it tries to record $soldUnits sold units from only $beforeQuantity recorded units in ${_stockLabel(before)}. Correct the physical stock or reduce the sale quantity first. Nothing was changed.',
        saleIds: List.unmodifiable(saleIds),
        stockIds: List.unmodifiable(<String>[entry.key]),
      );
    }

    final expectedRemaining = beforeQuantity - soldUnits;
    if (after.quantity != expectedRemaining) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this transaction because the sale ledger and stock delta do not reconcile. ${_stockLabel(before)} should move from $beforeQuantity to $expectedRemaining units after recording $soldUnits sold units, but the proposed stock state says ${after.quantity == null ? 'unknown' : after.quantity}. Nothing was changed.',
        saleIds: List.unmodifiable(saleIds),
        stockIds: List.unmodifiable(<String>[entry.key]),
      );
    }
    if (after.sold && expectedRemaining != 0) {
      return SaleLedgerMutationBlock(
        message:
            'Aaris blocked this transaction because the stock row is being marked SOLD while $expectedRemaining recorded units would remain after the sale. Nothing was changed.',
        saleIds: List.unmodifiable(saleIds),
        stockIds: List.unmodifiable(<String>[entry.key]),
      );
    }
  }

  return null;
}

void ensureSafeSaleLedgerMutation({
  required Map<String, Medicine> beforeRecords,
  required Map<String, Medicine> afterRecords,
  required Map<String, SaleEvent> beforeSales,
  required Iterable<SaleEvent> upsertSales,
  required Iterable<String> removeSaleIds,
  required DateTime now,
}) {
  final block = saleLedgerMutationBlock(
    beforeRecords: beforeRecords,
    afterRecords: afterRecords,
    beforeSales: beforeSales,
    upsertSales: upsertSales,
    removeSaleIds: removeSaleIds,
    now: now,
  );
  if (block != null) throw StateError(block.message);
}
