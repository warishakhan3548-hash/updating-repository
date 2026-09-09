import 'inventory_integrity.dart';
import 'medicine.dart';

/// High-level stock operations that rely on saved physical-lot facts.
enum PharmacyAutomationOperation {
  fefoSale,
  directSale,
  receiveStock,
  markSold,
}

class PharmacyAutomationBlock {
  const PharmacyAutomationBlock({
    required this.operation,
    required this.issue,
  });

  final PharmacyAutomationOperation operation;
  final InventoryIntegrityIssue issue;

  String get message {
    final action = switch (operation) {
      PharmacyAutomationOperation.fefoSale => 'FEFO sale',
      PharmacyAutomationOperation.directSale => 'sale',
      PharmacyAutomationOperation.receiveStock => 'stock receipt',
      PharmacyAutomationOperation.markSold => 'SOLD action',
    };
    return 'Aaris paused this $action because saved rows that appear to describe the same physical lot disagree on important facts. Open Needs attention, verify the physical packs, and correct the conflicting batch facts before continuing. Nothing was changed.';
  }
}

/// Deterministic fail-closed gate between cross-row integrity intelligence and
/// stock automation.
///
/// The integrity engine already detects strongly anchored physical-lot
/// contradictions. This guard turns those findings into executable safety
/// policy: dispensing, receiving and whole-stock SOLD automation cannot proceed
/// through a row whose physical-lot facts are contradictory. Manual correction,
/// archive and review flows remain available so the pharmacist can repair the
/// source facts instead of being locked out.
PharmacyAutomationBlock? automationIntegrityBlock({
  required Iterable<Medicine> medicines,
  required Iterable<String> candidateStockIds,
  required DateTime today,
  required PharmacyAutomationOperation operation,
}) {
  final ids = candidateStockIds.toSet();
  if (ids.isEmpty) return null;

  final report = InventoryIntegrityReport.build(
    medicines: medicines,
    today: today,
  );
  for (final issue in report.issues) {
    if (issue.kind != InventoryIntegrityKind.conflictingLotFacts) continue;
    if (issue.stockIds.any(ids.contains)) {
      return PharmacyAutomationBlock(operation: operation, issue: issue);
    }
  }
  return null;
}

void ensureAutomationIntegrity({
  required Iterable<Medicine> medicines,
  required Iterable<String> candidateStockIds,
  required DateTime today,
  required PharmacyAutomationOperation operation,
}) {
  final block = automationIntegrityBlock(
    medicines: medicines,
    candidateStockIds: candidateStockIds,
    today: today,
    operation: operation,
  );
  if (block != null) throw StateError(block.message);
}

/// Returns only contradictions that are genuinely introduced by the proposed
/// state. Existing conflicts do not make data repair impossible: if the after
/// conflict is entirely contained inside one conflict that was already present,
/// it is considered pre-existing (including a repair that removes one member
/// from a larger conflicting group).
List<InventoryIntegrityIssue> newlyIntroducedLotConflicts({
  required Iterable<Medicine> before,
  required Iterable<Medicine> after,
  required DateTime today,
}) {
  List<InventoryIntegrityIssue> conflicts(Iterable<Medicine> records) =>
      InventoryIntegrityReport.build(medicines: records, today: today)
          .issues
          .where(
            (issue) =>
                issue.kind == InventoryIntegrityKind.conflictingLotFacts,
          )
          .toList(growable: false);

  final existing = conflicts(before);
  final proposed = conflicts(after);
  return proposed.where((issue) {
    final proposedIds = issue.stockIds.toSet();
    return !existing.any((old) {
      final oldIds = old.stockIds.toSet();
      return proposedIds.every(oldIds.contains);
    });
  }).toList(growable: false);
}

void ensureNoNewLotConflicts({
  required Iterable<Medicine> before,
  required Iterable<Medicine> after,
  required DateTime today,
  String action = 'change',
}) {
  final conflicts = newlyIntroducedLotConflicts(
    before: before,
    after: after,
    today: today,
  );
  if (conflicts.isEmpty) return;
  throw StateError(
    'Aaris blocked this $action because it would create conflicting saved facts for a strongly matched physical batch. Verify the batch, barcode, expiry and manufacturing date instead of creating two contradictory versions of the same lot. Nothing was changed.',
  );
}
