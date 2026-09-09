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
  });

  final String productKey;
  final String title;
  final int requestedQuantity;
  final int plannedQuantity;
  final int knownVisibleUnits;
  final List<FefoAllocation> allocations;
  final List<String> unknownQuantityStockIds;

  int get remainingQuantity => requestedQuantity - plannedQuantity;
  bool get blockedByUnknownQuantity => unknownQuantityStockIds.isNotEmpty;
  bool get complete => remainingQuantity == 0 && !blockedByUnknownQuantity;
  bool get requiresExpiryVerification =>
      allocations.any((allocation) => allocation.expiry == null);
}

class ReviewedFefoSale {
  const ReviewedFefoSale({
    required this.baseRevision,
    required this.occurredAt,
    required this.plan,
  });

  final int baseRevision;
  final DateTime occurredAt;
  final FefoDispensingPlan plan;
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

  final candidates = dispensingCandidates(records, requested, date);
  final knownVisibleUnits = candidates
      .where((medicine) => medicine.quantity != null)
      .fold<int>(0, (sum, medicine) => sum + medicine.quantity!);
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
  );
}
