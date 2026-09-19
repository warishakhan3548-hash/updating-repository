import 'dart:math' as math;

import 'daily_demand.dart';
import 'inventory.dart';
import 'medicine.dart';

class BatchDemandProjection {
  const BatchDemandProjection(
    this.stock,
    this.daysUntilExpiry,
    this.unsoldUnits,
  );
  final Medicine stock;
  final int daysUntilExpiry;
  final double unsoldUnits;
  int get atRiskUnits => ceilStockUnits(unsoldUnits);
}

/// One FEFO allocation for purchase planning and expiry warnings. Only demand
/// actually consumed by an earlier batch is deducted from a later batch's
/// demand. Surplus that expires cannot absorb sales after its expiry date.
class StockDemandProjection {
  StockDemandProjection._(this.batches, this.quantity, this.coverageDays);
  final List<BatchDemandProjection> batches;
  final int quantity;
  final double coverageDays;

  static StockDemandProjection? build({
    required Iterable<Medicine> medicines,
    required DateTime today,
    required DailyDemandProfile demand,
  }) {
    if (!demand.hasEstimate) return null;
    final rows = medicines.where((m) => isDispensableOn(m, today)).toList();
    if (rows.any(
      (m) => m.quantity == null || (m.quantity! > 0 && m.expiry == null),
    ))
      return null;
    rows.removeWhere((m) => m.quantity == 0);
    rows.sort((a, b) {
      final expiry = civilDay(a.expiry!).compareTo(civilDay(b.expiry!));
      if (expiry != 0) return expiry;
      final batch = normalize(a.batchNumber)
          .compareTo(normalize(b.batchNumber));
      return batch != 0 ? batch : a.id.compareTo(b.id);
    });
    var consumed = 0.0;
    var quantity = 0;
    final batches = <BatchDemandProjection>[];
    for (final row in rows) {
      final days = row.daysLeft(today)!;
      final availableDemand = math.max(
        0.0,
        demand.demandForDays(days + 1) - consumed,
      );
      final take = math.min(row.quantity!.toDouble(), availableDemand);
      consumed += take;
      quantity += row.quantity!;
      batches.add(BatchDemandProjection(row, days, row.quantity! - take));
    }
    final remainingToday = demand.remainingTodayDemand;
    final coverage = quantity == 0 || consumed == 0
        ? 0.0
        : consumed <= remainingToday
        ? consumed / demand.planningUnitsPerDay
        : 1 + (consumed - remainingToday) / demand.planningUnitsPerDay;
    return StockDemandProjection._(
      List.unmodifiable(batches),
      quantity,
      coverage,
    );
  }

  /// Window includes today: seven days ends on today's date + six days.
  double wasteWithinDays(int days) {
    if (days < 1) throw ArgumentError.value(days, 'days');
    return batches
        .where((b) => b.daysUntilExpiry < days)
        .fold<double>(0, (sum, batch) => sum + batch.unsoldUnits);
  }

  int expiringWithinDays(int days) {
    if (days < 1) throw ArgumentError.value(days, 'days');
    return batches
        .where((b) => b.daysUntilExpiry < days)
        .fold<int>(0, (sum, batch) => sum + batch.stock.quantity!);
  }
}

/// Avoid an extra unit caused only by floating-point noise at an integer edge.
int ceilStockUnits(double units) => math.max(0, (units - 1e-9).ceil());
