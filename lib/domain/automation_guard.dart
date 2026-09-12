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
) => InventoryIntegrityReport.build(medicines: records, today: today).issues
    .where((issue) => issue.kind == InventoryIntegrityKind.conflictingLotFacts)
    .toList(growable: false);

Map<String, Set<String>> _barcodeIdentityConflicts(Iterable<Medicine> records) {
  final groups = <String, List<Medicine>>{};
  for (final medicine in records.where((medicine) => !medicine.archived)) {
    final barcode = medicine.barcode.trim();
    if (barcode.isEmpty) continue;
    groups.putIfAbsent(barcode, () => <Medicine>[]).add(medicine);
  }

  final conflicts = <String, Set<String>>{};
  for (final entry in groups.entries) {
    if (entry.value.map((medicine) => medicine.identity).toSet().length < 2) {
      continue;
    }
    conflicts[entry.key] = entry.value.map((medicine) => medicine.id).toSet();
  }
  return conflicts;
}

Set<String> _futureManufactureIds(Iterable<Medicine> records, DateTime today) {
  final day = civilDay(today);
  return records
      .where(
        (medicine) =>
            !medicine.archived &&
            !medicine.sold &&
            medicine.mfg != null &&
            civilDay(medicine.mfg!).isAfter(day),
      )
      .map((medicine) => medicine.id)
      .toSet();
}

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
  return proposed
      .where((issue) {
        final proposedIds = issue.stockIds.toSet();
        return !existing.any((old) {
          final oldIds = old.stockIds.toSet();
          return proposedIds.every(oldIds.contains);
        });
      })
      .toList(growable: false);
}

Map<String, Set<String>> _newBarcodeIdentityConflicts({
  required Iterable<Medicine> before,
  required Iterable<Medicine> after,
}) {
  final existing = _barcodeIdentityConflicts(before);
  final proposed = _barcodeIdentityConflicts(after);
  return {
    for (final entry in proposed.entries)
      if (existing[entry.key] == null ||
          !entry.value.every(existing[entry.key]!.contains))
        entry.key: entry.value,
  };
}

bool _introducesFutureManufactureDate({
  required Medicine? before,
  required Medicine after,
  required DateTime today,
}) {
  if (after.archived || after.sold || after.mfg == null) return false;
  final day = civilDay(today);
  if (!civilDay(after.mfg!).isAfter(day)) return false;
  if (before == null || before.archived || before.sold || before.mfg == null) {
    return true;
  }
  return !civilDay(before.mfg!).isAfter(day);
}

/// Persistence-boundary policy for the authoritative medicine database.
///
/// This is the deterministic safety kernel underneath manual UI, Aaris Brain,
/// scanner review and AI-reviewed writes. It protects three operational facts
/// that must never depend on whichever caller happened to initiate a mutation:
///
/// * strongly anchored physical lots may not gain contradictory saved facts;
/// * one barcode may not silently become authoritative for different medicine
///   identities, because scanner exact-match automation would become unsafe;
/// * active stock may not newly acquire an impossible future manufacturing date,
///   and existing future-MFG rows cannot move stock until corrected.
///
/// Existing bad data remains repairable: note-only edits, archive/removal, and a
/// correction that actually resolves the unsafe condition are allowed. Undo and
/// explicitly reviewed backup recovery are handled by the persistence layer and
/// bypass this prospective guard so exact historical recovery remains possible.
InventoryIntegrityMutationBlock? inventoryIntegrityMutationBlock({
  required Map<String, Medicine> before,
  required Map<String, Medicine> after,
  required Iterable<String> touchedStockIds,
  required DateTime today,
}) {
  final touched = touchedStockIds.toSet();
  if (touched.isEmpty) return null;

  final introducedLots = newlyIntroducedLotConflicts(
    before: before.values,
    after: after.values,
    today: today,
  );
  if (introducedLots.isNotEmpty) {
    final ids =
        introducedLots.expand((issue) => issue.stockIds).toSet().toList()
          ..sort();
    return InventoryIntegrityMutationBlock(
      stockIds: List.unmodifiable(ids),
      message: 'Aaris blocked this change because it would create conflicting saved facts for a strongly matched physical batch. Verify the batch, barcode, expiry and manufacturing date instead of saving two contradictory versions of the same lot. Nothing was changed.',
    );
  }

  final introducedBarcodes = _newBarcodeIdentityConflicts(
    before: before.values,
    after: after.values,
  );
  if (introducedBarcodes.isNotEmpty) {
    final ids = introducedBarcodes.values.expand((ids) => ids).toSet().toList()
      ..sort();
    final barcode = introducedBarcodes.keys.first;
    return InventoryIntegrityMutationBlock(
      stockIds: List.unmodifiable(ids),
      message:
          'Aaris blocked this change because barcode $barcode would point to different medicine identities. Verify the physical packs or correct the barcode before scanner or stock automation can trust it. Nothing was changed.',
    );
  }

  for (final id in touched) {
    final next = after[id];
    if (next == null) continue;
    if (_introducesFutureManufactureDate(
      before: before[id],
      after: next,
      today: today,
    )) {
      return InventoryIntegrityMutationBlock(
        stockIds: List.unmodifiable(<String>[id]),
        message: 'Aaris blocked this change because it would save active stock with a manufacturing date in the future. Verify the printed MFG date before saving; nothing was changed.',
      );
    }
  }

  final beforeLotIssues = _lotConflicts(before.values, today);
  final beforeLotIds = beforeLotIssues
      .expand((issue) => issue.stockIds)
      .toSet();
  final afterLotIds = _lotConflicts(
    after.values,
    today,
  ).expand((issue) => issue.stockIds).toSet();
  final beforeBarcodeGroups = _barcodeIdentityConflicts(before.values);
  final afterBarcodeGroups = _barcodeIdentityConflicts(after.values);
  final beforeBarcodeIds = beforeBarcodeGroups.values
      .expand((ids) => ids)
      .toSet();
  final afterBarcodeIds = afterBarcodeGroups.values
      .expand((ids) => ids)
      .toSet();
  final beforeFutureIds = _futureManufactureIds(before.values, today);
  final afterFutureIds = _futureManufactureIds(after.values, today);

  for (final id in touched) {
    final old = before[id];
    final next = after[id];
    if (old == null || next == null || next.archived) continue;

    final blockedBefore =
        beforeLotIds.contains(id) ||
        beforeBarcodeIds.contains(id) ||
        beforeFutureIds.contains(id);
    if (!blockedBefore) continue;

    final blockedAfter =
        afterLotIds.contains(id) ||
        afterBarcodeIds.contains(id) ||
        afterFutureIds.contains(id);
    final stockStateChanged =
        old.quantity != next.quantity ||
        old.sold != next.sold ||
        old.soldAt != next.soldAt ||
        old.soldQuantity != next.soldQuantity ||
        old.soldUnitPricePaise != next.soldUnitPricePaise;
    final identityFactsChanged =
        old.identity != next.identity ||
        normalize(old.batchNumber) != normalize(next.batchNumber) ||
        normalize(old.barcode) != normalize(next.barcode) ||
        normalize(old.manufacturer) != normalize(next.manufacturer) ||
        normalize(old.brand) != normalize(next.brand) ||
        old.mfg != next.mfg ||
        old.expiry != next.expiry;

    if (!stockStateChanged && !identityFactsChanged) continue;
    if (!blockedAfter && identityFactsChanged) continue;

    final reason = beforeBarcodeIds.contains(id)
        ? 'a barcode identity conflict'
        : beforeFutureIds.contains(id)
        ? 'a manufacturing date in the future'
        : 'conflicting saved batch facts';
    return InventoryIntegrityMutationBlock(
      stockIds: List.unmodifiable(<String>[id]),
      message: stockStateChanged
          ? 'Aaris paused this stock movement because this row has $reason. Open Needs attention, verify the physical pack, and correct or archive the unsafe row before changing quantity or SOLD state. Nothing was changed.'
          : 'Aaris blocked this identity/batch edit because the row would still have $reason after saving. Resolve the unsafe facts completely first; nothing was changed.',
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
