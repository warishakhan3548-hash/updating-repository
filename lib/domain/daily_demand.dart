import 'dart:math' as math;

import 'medicine.dart';

enum DemandTrend { rising, falling, steady, insufficient }

class DailySaleTotal {
  const DailySaleTotal(this.day, this.units);
  final DateTime day;
  final int units;
}

/// A bounded, read-only view of recorded sales. Zero means no sale was recorded,
/// not proof that the shop was open, in stock, or had no unmet customer demand.
class DailyDemandProfile {
  DailyDemandProfile._({
    required this.today,
    required List<DailySaleTotal> days,
    required this.todayUnits,
    required this.recordedSales,
    required this.observedDays,
    required this.historySpanDays,
    required this.sellingDays,
    required this.recentWeekUnits,
    required this.previousWeekUnits,
    required this.planningUnitsPerDay,
    required this.dailyDeviation,
    required this.variableSales,
    required this.identityConflict,
    required this.historyNeedsReview,
  }) : days = List.unmodifiable(days);

  final DateTime today;

  /// Thirty completed civil days, oldest first. Today is separate and partial.
  final List<DailySaleTotal> days;
  final int todayUnits,
      recordedSales,
      observedDays,
      historySpanDays,
      sellingDays;
  final int recentWeekUnits, previousWeekUnits;
  final double planningUnitsPerDay, dailyDeviation;
  final bool variableSales, identityConflict, historyNeedsReview;

  int get yesterdayUnits => days.last.units;
  int get unitsLast30Days =>
      todayUnits + days.skip(1).fold<int>(0, (sum, day) => sum + day.units);
  bool get usableHistory => !identityConflict && !historyNeedsReview;
  bool get hasEstimate => usableHistory && planningUnitsPerDay > 0;
  bool get reviewRequired =>
      !hasEstimate ||
      sellingDays < 3 ||
      historySpanDays < 7 ||
      variableSales ||
      recentWeekUnits == 0;

  /// Operational evidence tiers, not calibrated probabilities of future demand.
  double get confidence {
    if (!hasEstimate) return .35;
    if (reviewRequired) return .55;
    if (historySpanDays >= 21 && sellingDays >= 14) return .92;
    if (historySpanDays >= 14 && sellingDays >= 7) return .86;
    return .78;
  }

  DemandTrend get trend {
    if (!usableHistory ||
        historySpanDays < 14 ||
        sellingDays < 3 ||
        previousWeekUnits == 0 ||
        recentWeekUnits == 0) {
      return DemandTrend.insufficient;
    }
    final ratio = recentWeekUnits / previousWeekUnits;
    if (ratio >= 1.25) return DemandTrend.rising;
    if (ratio <= .75) return DemandTrend.falling;
    return DemandTrend.steady;
  }

  /// The remaining part of today's typical recorded demand. Today's sales
  /// update the count and stock immediately without treating a partial day as a
  /// completed zero day or charging its already-recorded demand a second time.
  double get remainingTodayDemand =>
      hasEstimate ? math.max(0.0, planningUnitsPerDay - todayUnits) : 0;

  double demandForDays(int days) {
    if (days < 1) throw ArgumentError.value(days, 'days');
    return hasEstimate
        ? remainingTodayDemand + planningUnitsPerDay * (days - 1)
        : 0;
  }

  /// A bounded variability allowance, not a claimed service-level guarantee.
  double bufferForDays(int days) {
    if (days < 1) throw ArgumentError.value(days, 'days');
    return hasEstimate
        ? math.min(planningUnitsPerDay * days, dailyDeviation * math.sqrt(days))
        : 0;
  }
}

/// Aggregate receipts before measuring evidence; splitting one sale into many
/// receipts on the same day must never increase forecast confidence.
class DailyDemandAccumulator {
  DailyDemandAccumulator(DateTime today) : today = civilDay(today);
  final DateTime today;
  final List<int> _raw = List.filled(31, 0);
  final List<int> _valid = List.filled(31, 0);
  int _recordedSales = 0;
  bool _invalidHistory = false;

  void add(DateTime occurredAt, int quantity, {bool valid = true}) {
    final age = today.difference(civilDay(occurredAt)).inDays;
    if (age < 0) {
      _invalidHistory = true;
      return;
    }
    if (age > 30) return;
    if (quantity <= 0) {
      _invalidHistory = true;
      return;
    }
    _raw[age] += quantity;
    if (age < 30) _recordedSales++;
    if (valid) {
      _valid[age] += quantity;
    } else {
      _invalidHistory = true;
    }
  }

  DailyDemandProfile build({bool identityConflict = false}) {
    var span = 0;
    var sellingDays = 0;
    for (var age = 1; age <= 30; age++) {
      if (_valid[age] > 0) {
        span = age;
        sellingDays++;
      }
    }
    final observedDays = span == 0 ? 0 : math.max(7, span);
    var weightSum = 0.0;
    var weightedUnits = 0.0;
    var sum = 0.0;
    // Seven-day half-life: recent completed days carry more weight. Normalize
    // the finite window rather than initializing from one potentially bulk sale.
    for (var age = 1; age <= observedDays; age++) {
      final weight = math.pow(.5, (age - 1) / 7).toDouble();
      weightSum += weight;
      weightedUnits += _valid[age] * weight;
      sum += _valid[age];
    }
    final average = observedDays == 0 ? 0.0 : sum / observedDays;
    var variance = 0.0;
    for (var age = 1; age <= observedDays; age++) {
      variance += math.pow(_valid[age] - average, 2).toDouble();
    }
    final deviation = observedDays == 0
        ? 0.0
        : math.sqrt(variance / observedDays);
    return DailyDemandProfile._(
      today: today,
      days: [
        for (var age = 30; age >= 1; age--)
          DailySaleTotal(today.subtract(Duration(days: age)), _raw[age]),
      ],
      todayUnits: _raw[0],
      recordedSales: _recordedSales,
      observedDays: observedDays,
      historySpanDays: span,
      sellingDays: sellingDays,
      recentWeekUnits: _raw.sublist(1, 8).fold(0, (sum, n) => sum + n),
      previousWeekUnits: _raw.sublist(8, 15).fold(0, (sum, n) => sum + n),
      planningUnitsPerDay: identityConflict || _invalidHistory || weightSum == 0
          ? 0
          : weightedUnits / weightSum,
      dailyDeviation: deviation,
      variableSales: average > 0 && deviation / average > 1.5,
      identityConflict: identityConflict,
      historyNeedsReview: _invalidHistory,
    );
  }
}
