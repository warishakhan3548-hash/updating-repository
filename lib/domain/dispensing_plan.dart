import 'dart:math';

import 'inventory.dart';
import 'medicine.dart';

class FefoAllocation {
  const FefoAllocation({
    required this.stockId,
    required this.quantity,
    required this.availableQuantity,
    required this.batchNumber,
    required this.address,
    required this.expiry,
    required this.expiryMonthOnly,
  });

  final String stockId;
  final int quantity;
  final int availableQuantity;
  final String batchNumber;
  final String address;
  final DateTime? expiry;
  final bool expiryMonthOnly;

  bool get emptiesStock => quantity == availableQuantity;
}

class FefoDispensingPlan {
  const FefoDispensingPlan({
    required this.productKey,
    required this.title,
    required this.requestedQuantity,
    required this.plannedQuantity,
    required this.knownVisibleUnits,
    required this.allocations,
    required this.unknownQuantityStockIds,
    this.unknownExpiryStockIds = const <String>[],
  });

  final String productKey;
  final String title;
  final int requestedQuantity;
  final int plannedQuantity;
  final int knownVisibleUnits;
  final List<FefoAllocation> allocations;
  final List<String> unknownQuantityStockIds;

  /// Active same-product rows whose expiry is missing. Their relative FEFO
  /// priority is unknowable, so an automated sale must fail closed until the
  /// physical expiry is verified and saved instead of silently skipping them.
  final List<String> unknownExpiryStockIds;

  int get remainingQuantity => requestedQuantity - plannedQuantity;
  bool get blockedByUnknownQuantity => unknownQuantityStockIds.isNotEmpty;
  bool get blockedByUnknownExpiry => unknownExpiryStockIds.isNotEmpty;
  bool get complete =>
      remainingQuantity == 0 &&
      !blockedByUnknownQuantity &&
      !blockedByUnknownExpiry;
  bool get requiresExpiryVerification =>
      blockedByUnknownExpiry ||
      allocations.any((allocation) => allocation.expiry == null);
}

class ReviewedFefoSale {
  const ReviewedFefoSale({
    required this.baseRevision,
    required this.occurredAt,
    required this.plan,
    this.stockRevisions = const <String, int>{},
  });

  final int baseRevision;
  final DateTime occurredAt;
  final FefoDispensingPlan plan;

  /// Exact revisions for physical rows shown in the reviewed allocation.
  /// They let the controller distinguish harmless unrelated inventory traffic
  /// from a change to stock the pharmacist actually reviewed.
  final Map<String, int> stockRevisions;
}

FefoDispensingPlan planFefoDispensing({
  required Iterable<Medicine> records,
  required Medicine requested,
  required int quantity,
  required DateTime date,
}) {
  if (quantity < 1 || quantity > 100000000) {
    throw const FormatException(
      'Dispensing quantity must be a positive whole number.',
    );
  }

  // `Medicine.identity` intentionally stays stable when OCR salt metadata is
  // corrected later, which is useful for search/history but is too permissive
  // to be the sole authority for a dispensing allocation. Before FEFO can move
  // stock across physical rows, fail closed when those otherwise-same product
  // rows contain two different *known* compositions. Missing salt remains an
  // explicit unknown fact; a recorded contradiction is never silently ignored.
  final knownCompositions = <String>{};
  final requestedComposition = identityPart(requested.salt);
  if (requestedComposition.isNotEmpty) {
    knownCompositions.add(requestedComposition);
  }
  for (final record in records) {
    if (record.identity != requested.identity ||
        !isDispensableOn(record, date) ||
        record.quantity == 0) {
      continue;
    }
    final composition = identityPart(record.salt);
    if (composition.isNotEmpty) knownCompositions.add(composition);
    if (knownCompositions.length > 1) {
      throw const FormatException(
        'FEFO is blocked because same-name stock rows have conflicting recorded salts. Verify the exact medicine composition before recording this sale.',
      );
    }
  }

  final candidates = dispensingCandidates(records, requested, date);
  final knownVisibleUnits = candidates
      .where((medicine) => medicine.quantity != null)
      .fold<int>(0, (sum, medicine) => sum + medicine.quantity!);
  final unknownExpiryStockIds = candidates
      .where((medicine) => medicine.expiry == null)
      .map((medicine) => medicine.id)
      .toList(growable: false);

  // FEFO is only deterministic when every eligible physical row has a recorded
  // expiry. A row with unknown expiry could be the true earliest-expiring pack;
  // allocating a later known-expiry row first would falsely claim FEFO. Keep the
  // operation read-only until the pharmacist records the missing pack expiry.
  if (unknownExpiryStockIds.isNotEmpty) {
    return FefoDispensingPlan(
      productKey: requested.identity,
      title: requested.title,
      requestedQuantity: quantity,
      plannedQuantity: 0,
      knownVisibleUnits: knownVisibleUnits,
      allocations: const <FefoAllocation>[],
      unknownQuantityStockIds: candidates
          .where((medicine) => medicine.quantity == null)
          .map((medicine) => medicine.id)
          .toList(growable: false),
      unknownExpiryStockIds: List<String>.unmodifiable(unknownExpiryStockIds),
    );
  }

  final allocations = <FefoAllocation>[];
  final blockers = <String>[];
  var remaining = quantity;

  for (final medicine in candidates) {
    if (remaining == 0) break;
    final available = medicine.quantity;
    if (available == null) {
      // An unknown-quantity batch cannot be silently skipped because it may be
      // the true FEFO batch. Stop and require physical verification.
      blockers.add(medicine.id);
      break;
    }
    if (available <= 0) continue;
    final take = min(available, remaining);
    allocations.add(
      FefoAllocation(
        stockId: medicine.id,
        quantity: take,
        availableQuantity: available,
        batchNumber: medicine.batchNumber,
        address: medicine.address,
        expiry: medicine.expiry,
        expiryMonthOnly: medicine.expiryMonthOnly,
      ),
    );
    remaining -= take;
  }

  return FefoDispensingPlan(
    productKey: requested.identity,
    title: requested.title,
    requestedQuantity: quantity,
    plannedQuantity: quantity - remaining,
    knownVisibleUnits: knownVisibleUnits,
    allocations: List.unmodifiable(allocations),
    unknownQuantityStockIds: List.unmodifiable(blockers),
    unknownExpiryStockIds: const <String>[],
  );
}
