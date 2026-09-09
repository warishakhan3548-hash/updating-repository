import 'inventory_integrity.dart';
import 'medicine.dart';

/// High-level stock operations that can rely on saved lot facts without a
/// pharmacist manually resolving every conflicting row first.
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
/// contradictions. This guard makes those findings executable safety policy:
/// FEFO/dispensing, receiving and whole-stock SOLD automation cannot proceed
/// through a row whose physical-lot facts are contradictory. Manual editor,
/// archive and correction flows remain available so the pharmacist can repair
/// the source facts instead of being locked out.
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
