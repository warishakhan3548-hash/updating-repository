import 'inventory_integrity.dart';
import 'medicine.dart';

class InventoryIntegrityMutationBlock {
  const InventoryIntegrityMutationBlock({
    required this.message,
    required this.stockIds,
  });

  final String message;
  final List<String> stockIds;
}

List<InventoryIntegrityIssue> _lotConflicts(
  Iterable<Medicine> records,
  DateTime today,
) => InventoryIntegrityReport.build(medicines: records, today: today)
    .issues
    .where((issue) => issue.kind == InventoryIntegrityKind.conflictingLotFacts)
    .toList(growable: false);

/// Returns only physical-lot contradictions that are genuinely introduced by
/// the proposed state. A reduced subset of a conflict that already existed is
/// not treated as new, so a pharmacist can repair or archive bad rows without
/// being trapped by the safety gate.
List<InventoryIntegrityIssue> newlyIntroducedLotConflicts({
  required Iterable<Medicine> before,
  required Iterable<Medicine> after,
  required DateTime today,
}) {
  final existing = _lotConflicts(before, today);
  final proposed = _lotConflicts(after, today);
  return proposed.where((issue) {
    final proposedIds = issue.stockIds.toSet();
    return !existing.any((old) {
      final oldIds = old.stockIds.toSet();
      return proposedIds.every(oldIds.contains);
    });
  }).toList(growable: false);
}

/// Persistence-boundary policy for the authoritative medicine database.
///
/// Strongly anchored physical-lot contradictions (same product/batch plus a
/// barcode, manufacturer or brand anchor) are not merely warnings anymore:
///
/// * a transaction may not create a new contradiction;
/// * quantity/SOLD automation may not continue through an already-conflicting
///   physical lot;
/// * editing the lot-defining facts of an already-conflicting row must actually
///   resolve that row's conflict rather than replace one contradiction with
///   another;
/// * archive/removal remains available so bad duplicate rows can be retired;
/// * unrelated metadata edits remain available and do not dead-lock the user.
///
/// This is deterministic, local-only and uses only facts already saved by the
/// pharmacist. It never invents medicine or clinical facts.
InventoryIntegrityMutationBlock? inventoryIntegrityMutationBlock({
  required Map<String, Medicine> before,
  required Map<String, Medicine> after,
  required Iterable<String> touchedStockIds,
  required DateTime today,
}) {
  final touched = touchedStockIds.toSet();
  if (touched.isEmpty) return null;

  final introduced = newlyIntroducedLotConflicts(
    before: before.values,
    after: after.values,
    today: today,
  );
  if (introduced.isNotEmpty) {
    final ids = introduced.expand((issue) => issue.stockIds).toSet().toList()
      ..sort();
    return InventoryIntegrityMutationBlock(
      stockIds: List.unmodifiable(ids),
      message:
          'Aaris blocked this change because it would create conflicting saved facts for a strongly matched physical batch. Verify the batch, barcode, expiry and manufacturing date instead of saving two contradictory versions of the same lot. Nothing was changed.',
    );
  }

  final beforeConflicts = _lotConflicts(before.values, today);
  if (beforeConflicts.isEmpty) return null;
  final beforeConflictedIds = beforeConflicts
      .expand((issue) => issue.stockIds)
      .toSet();
  final afterConflictedIds = _lotConflicts(after.values, today)
      .expand((issue) => issue.stockIds)
      .toSet();

  for (final id in touched) {
    if (!beforeConflictedIds.contains(id)) continue;
    final old = before[id];
    final next = after[id];
    if (old == null || next == null || next.archived) continue;

    final stockStateChanged =
        old.quantity != next.quantity ||
        old.sold != next.sold ||
        old.soldAt != next.soldAt ||
        old.soldQuantity != next.soldQuantity ||
        old.soldUnitPricePaise != next.soldUnitPricePaise;
    final lotFactsChanged =
        old.identity != next.identity ||
        normalize(old.batchNumber) != normalize(next.batchNumber) ||
        normalize(old.barcode) != normalize(next.barcode) ||
        normalize(old.manufacturer) != normalize(next.manufacturer) ||
        normalize(old.brand) != normalize(next.brand) ||
        old.mfg != next.mfg ||
        old.expiry != next.expiry;

    if (!stockStateChanged && !lotFactsChanged) continue;
    if (!afterConflictedIds.contains(id) && lotFactsChanged) continue;

    return InventoryIntegrityMutationBlock(
      stockIds: List.unmodifiable(<String>[id]),
      message: stockStateChanged
          ? 'Aaris paused this stock movement because this row belongs to a physical lot with conflicting saved batch facts. Open Needs attention, verify the physical packs, and correct or archive the conflicting row before changing quantity or SOLD state. Nothing was changed.'
          : 'Aaris blocked this batch edit because the row would still have contradictory physical-lot facts after saving. Verify the pack and resolve the conflict completely first. Nothing was changed.',
    );
  }

  return null;
}

void ensureIntegritySafeInventoryMutation({
  required Map<String, Medicine> before,
  required Map<String, Medicine> after,
  required Iterable<String> touchedStockIds,
  required DateTime today,
}) {
  final block = inventoryIntegrityMutationBlock(
    before: before,
    after: after,
    touchedStockIds: touchedStockIds,
    today: today,
  );
  if (block != null) throw StateError(block.message);
}
