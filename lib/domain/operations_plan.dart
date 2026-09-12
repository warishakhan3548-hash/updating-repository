import 'attention.dart';
import 'medicine.dart';

enum OperationsLane {
  safety,
  verification,
  stock,
  location,
  expiry,
  purchasing,
}

class OperationsPlanStep {
  const OperationsPlanStep({
    required this.item,
    required this.lane,
    required this.actionLabel,
    required this.prerequisites,
  });

  final AttentionItem item;
  final OperationsLane lane;
  final String actionLabel;
  final List<AttentionItem> prerequisites;

  bool get blocked => prerequisites.isNotEmpty;

  String get laneLabel => switch (lane) {
    OperationsLane.safety => 'Safety first',
    OperationsLane.verification => 'Verify facts',
    OperationsLane.stock => 'Fix stock state',
    OperationsLane.location => 'Make stock findable',
    OperationsLane.expiry => 'Protect expiry flow',
    OperationsLane.purchasing => 'Review purchasing',
  };
}

/// Turns the deterministic Needs Attention findings into a pharmacist work plan.
///
/// This planner never writes inventory and never invents medicine facts. Its job
/// is dependency ordering: data-integrity and physical-fact blockers are placed
/// before downstream FEFO/reorder work that depends on those facts. A blocked
/// step remains visible, but callers can route the pharmacist to its prerequisite
/// instead of encouraging a decision from incomplete data.
class PharmacyOperationsPlan {
  PharmacyOperationsPlan._(List<OperationsPlanStep> source)
    : steps = List.unmodifiable(source);

  factory PharmacyOperationsPlan.build({
    required Iterable<AttentionItem> items,
    required Iterable<Medicine> medicines,
  }) {
    final source = items.toList(growable: false);
    final identityByStockId = <String, String>{
      for (final medicine in medicines) medicine.id: medicine.identity,
    };
    final originalIndex = <String, int>{};
    for (var index = 0; index < source.length; index++) {
      originalIndex.putIfAbsent(source[index].key, () => index);
    }

    final blockers = source
        .where((item) => _isDependencyPrerequisite(item.kind))
        .toList(growable: false);
    final steps = <OperationsPlanStep>[];
    for (final item in source) {
      final prerequisites = _dependsOnVerifiedFacts(item.kind)
          ? blockers
                .where(
                  (blocker) =>
                      blocker.key != item.key &&
                      _blocksDependent(item.kind, blocker.kind) &&
                      _related(item, blocker, identityByStockId),
                )
                .toList(growable: false)
          : const <AttentionItem>[];
      steps.add(
        OperationsPlanStep(
          item: item,
          lane: _laneFor(item.kind),
          actionLabel: _actionFor(item.kind),
          prerequisites: List.unmodifiable(prerequisites),
        ),
      );
    }

    // Workflow lane is more useful than a flat severity sort: unsafe stock and
    // fact verification come before calculations that depend on those facts.
    // Within each lane, actionable work stays ahead of downstream blocked work.
    steps.sort((a, b) {
      final lane = a.lane.index.compareTo(b.lane.index);
      if (lane != 0) return lane;
      if (a.blocked != b.blocked) return a.blocked ? 1 : -1;
      final severity = a.item.severity.index.compareTo(b.item.severity.index);
      if (severity != 0) return severity;
      final sourceOrder = (originalIndex[a.item.key] ?? 1 << 30).compareTo(
        originalIndex[b.item.key] ?? 1 << 30,
      );
      if (sourceOrder != 0) return sourceOrder;
      return a.item.title.compareTo(b.item.title);
    });
    return PharmacyOperationsPlan._(steps);
  }

  final List<OperationsPlanStep> steps;

  bool get isEmpty => steps.isEmpty;
  int get blockedCount => steps.where((step) => step.blocked).length;
  int get readyCount => steps.length - blockedCount;
  int get verificationCount =>
      steps.where((step) => _isVerificationPrerequisite(step.item.kind)).length;

  OperationsPlanStep? get nextStep {
    for (final step in steps) {
      if (!step.blocked) return step;
    }
    return null;
  }
}

bool _related(
  AttentionItem left,
  AttentionItem right,
  Map<String, String> identityByStockId,
) {
  if (left.stockIds.any(right.stockIds.contains)) return true;
  final leftProducts = _productKeys(left, identityByStockId);
  if (leftProducts.isEmpty) return false;
  final rightProducts = _productKeys(right, identityByStockId);
  return leftProducts.any(rightProducts.contains);
}

Set<String> _productKeys(
  AttentionItem item,
  Map<String, String> identityByStockId,
) {
  final keys = <String>{};
  final explicit = item.productKey?.trim() ?? '';
  if (explicit.isNotEmpty) keys.add(explicit);
  for (final stockId in item.stockIds) {
    final identity = identityByStockId[stockId];
    if (identity != null && identity.isNotEmpty) keys.add(identity);
  }
  return keys;
}

bool _isDependencyPrerequisite(AttentionKind kind) =>
    kind == AttentionKind.missingStockLocation ||
    _isVerificationPrerequisite(kind);

bool _blocksDependent(AttentionKind dependent, AttentionKind prerequisite) {
  // A missing shelf/rack location is crucial for physical FEFO work but is not
  // evidence for demand or stock quantity. It must never block a valid reorder
  // merely because the pharmacist has not yet recorded where the pack is kept.
  if (prerequisite == AttentionKind.missingStockLocation) {
    return dependent == AttentionKind.shortExpiry ||
        dependent == AttentionKind.expiryWastePressure;
  }
  return true;
}

bool _isVerificationPrerequisite(AttentionKind kind) => switch (kind) {
  AttentionKind.barcodeConflict ||
  AttentionKind.conflictingLotFacts ||
  AttentionKind.possibleDuplicateBatch ||
  AttentionKind.unknownExpiry ||
  AttentionKind.unknownQuantity ||
  AttentionKind.futureManufactureDate ||
  AttentionKind.zeroQuantityMismatch ||
  AttentionKind.soldAuditGap ||
  AttentionKind.staleSoldMetadata ||
  AttentionKind.futureSaleHistory ||
  AttentionKind.saleLifecycleConflict => true,
  _ => false,
};

bool _dependsOnVerifiedFacts(AttentionKind kind) => switch (kind) {
  AttentionKind.shortExpiry ||
  AttentionKind.expiryWastePressure ||
  AttentionKind.urgentReorder ||
  AttentionKind.reorderReview => true,
  _ => false,
};

OperationsLane _laneFor(AttentionKind kind) => switch (kind) {
  AttentionKind.expiredStock => OperationsLane.safety,
  AttentionKind.barcodeConflict ||
  AttentionKind.conflictingLotFacts ||
  AttentionKind.possibleDuplicateBatch ||
  AttentionKind.futureManufactureDate ||
  AttentionKind.soldAuditGap ||
  AttentionKind.staleSoldMetadata ||
  AttentionKind.futureSaleHistory ||
  AttentionKind.saleLifecycleConflict => OperationsLane.verification,
  AttentionKind.zeroQuantityMismatch ||
  AttentionKind.unknownQuantity ||
  AttentionKind.unknownExpiry => OperationsLane.stock,
  AttentionKind.missingStockLocation => OperationsLane.location,
  AttentionKind.shortExpiry ||
  AttentionKind.expiryWastePressure => OperationsLane.expiry,
  AttentionKind.urgentReorder ||
  AttentionKind.reorderReview => OperationsLane.purchasing,
};

String _actionFor(AttentionKind kind) => switch (kind) {
  AttentionKind.expiredStock =>
    'Keep this stock out of dispensing and review its Expired removal.',
  AttentionKind.shortExpiry =>
    'Verify FEFO placement so this earlier-expiry stock is handled first.',
  AttentionKind.expiryWastePressure => 'Review FEFO placement and avoid adding stock until the recorded demand signal is checked.',
  AttentionKind.zeroQuantityMismatch =>
    'Confirm whether the row is truly SOLD or correct the physical quantity.',
  AttentionKind.missingStockLocation => 'Record the exact shelf/rack location so FEFO picking and retrieval can route to this stock without relying on memory.',
  AttentionKind.barcodeConflict => 'Verify the physical packs and correct the barcode-to-medicine identity conflict.',
  AttentionKind.conflictingLotFacts =>
    'Verify the physical lot and reconcile the conflicting saved batch facts.',
  AttentionKind.staleSoldMetadata => 'Review the stock row and reconcile stale SOLD metadata before using its history.',
  AttentionKind.soldAuditGap => 'Review the stock row and repair the audit gap before relying on sales history.',
  AttentionKind.futureSaleHistory => 'Verify the business date and historical sale source before relying on this demand signal.',
  AttentionKind.saleLifecycleConflict => 'Verify the physical MFG/EXP and sale-history source; keep immutable history unchanged until provenance is clear.',
  AttentionKind.urgentReorder => 'Open Order Review and confirm the urgent quantity from verified stock facts.',
  AttentionKind.reorderReview => 'Open Order Review and verify the suggested quantity before creating an order.',
  AttentionKind.unknownExpiry => 'Read the expiry from the physical pack and save it before relying on FEFO automation.',
  AttentionKind.unknownQuantity => 'Count the physical stock and save the exact quantity before automation continues.',
  AttentionKind.futureManufactureDate =>
    'Verify the physical MFG date and correct the saved fact if needed.',
  AttentionKind.possibleDuplicateBatch => 'Verify the physical stock rows; keep separate legitimate lots and remove only confirmed duplicates.',
};
