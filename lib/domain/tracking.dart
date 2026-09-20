import 'daily_demand.dart';
import 'inventory.dart';
import 'medicine.dart';
import 'stock_projection.dart';
import 'supplier.dart';

class SaleEvent {
  SaleEvent({
    required this.id,
    required this.stockId,
    required this.medicineName,
    required this.quantity,
    required this.occurredAt,
    this.strength = '',
    this.form = '',
    this.salt = '',
    this.totalAmountPaise,
    this.savedUnitPricePaise,
  });

  final String id;
  final String stockId;
  final String medicineName;
  final String strength;
  final String form;
  final String salt;
  final int quantity;
  final DateTime occurredAt;
  final int? totalAmountPaise;
  final int? savedUnitPricePaise;

  static const storedFields = <String>{
    'id',
    'stockId',
    'medicineName',
    'strength',
    'form',
    'salt',
    'quantity',
    'occurredAt',
    'totalAmountPaise',
    'savedUnitPricePaise',
  };

  String get productKey => medicineIdentity(medicineName, strength, form);
  String get title => '$medicineName${strength.isEmpty ? '' : ' · $strength'}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'stockId': stockId,
    'medicineName': medicineName,
    'strength': strength,
    'form': form,
    'salt': salt,
    'quantity': quantity,
    'occurredAt': occurredAt.toIso8601String(),
    'totalAmountPaise': totalAmountPaise,
    'savedUnitPricePaise': savedUnitPricePaise,
  };

  factory SaleEvent.fromJson(Map<String, dynamic> json) {
    String text(String key, {int max = 300}) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty || value.length > max) {
        throw FormatException('Invalid sale $key.');
      }
      return value.trim();
    }

    String optionalText(String key, {int max = 300}) {
      final value = json[key];
      if (value == null || value == '') return '';
      if (value is! String || value.length > max) {
        throw FormatException('Invalid sale $key.');
      }
      return value.trim();
    }

    int? amount(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! int || value < 0 || value > maxExactPaise) {
        throw FormatException('Invalid sale $key.');
      }
      return value;
    }

    final quantity = json['quantity'];
    if (quantity is! int || quantity < 1 || quantity > 100000000) {
      throw const FormatException(
        'Sale quantity must be a positive whole number.',
      );
    }
    final occurredAtRaw = json['occurredAt'];
    final occurredAt = occurredAtRaw is String
        ? DateTime.tryParse(occurredAtRaw)
        : null;
    if (occurredAt == null ||
        occurredAt.year < 2000 ||
        occurredAt.year > 2200) {
      throw const FormatException('Invalid sale date.');
    }
    return SaleEvent(
      id: text('id'),
      stockId: text('stockId'),
      medicineName: text('medicineName'),
      strength: optionalText('strength'),
      form: normalizeForm(optionalText('form')),
      salt: optionalText('salt'),
      quantity: quantity,
      occurredAt: occurredAt,
      totalAmountPaise: amount('totalAmountPaise'),
      savedUnitPricePaise: amount('savedUnitPricePaise'),
    );
  }
}

class TrackingRange {
  TrackingRange({required DateTime start, required DateTime end})
    : start = civilDay(start),
      end = civilDay(end) {
    if (this.start.isAfter(this.end)) {
      throw const FormatException(
        'Tracking start date must be before the end date.',
      );
    }
    if (days > 3660) {
      throw const FormatException(
        'Choose a tracking period of 10 years or less.',
      );
    }
  }

  factory TrackingRange.lastDays(DateTime today, int days) {
    if (days < 1 || days > 3660) {
      throw const FormatException('Choose between 1 and 3660 days.');
    }
    final end = civilDay(today);
    return TrackingRange(
      start: end.subtract(Duration(days: days - 1)),
      end: end,
    );
  }

  final DateTime start;
  final DateTime end;
  int get days => end.difference(start).inDays + 1;

  bool contains(DateTime value) {
    final day = civilDay(value);
    return !day.isBefore(start) && !day.isAfter(end);
  }
}

class ProductMovement {
  ProductMovement({
    required this.key,
    required this.name,
    required this.salt,
    required this.strength,
    required this.form,
  });

  final String key;
  final String name;
  final String salt;
  final String strength;
  final String form;
  int unitsSold = 0;
  int recordedSales = 0;
  int knownRevenuePaise = 0;
  int unknownRevenueSales = 0;
  int? currentQuantity;
  bool identityConflict = false;
  DailyDemandProfile? demand;
  double? coverageDays;
  double get unitsPerDay => _periodDays == 0 ? 0 : unitsSold / _periodDays;
  int _periodDays = 1;
  String get title => '$name${strength.isEmpty ? '' : ' · $strength'}';
}

enum ReorderPriority { urgent, soon }

class ReorderSuggestion {
  const ReorderSuggestion({
    required this.productKey,
    required this.name,
    required this.salt,
    required this.strength,
    required this.form,
    required this.priority,
    required this.reason,
    required this.suggestedQuantity,
    required this.unitsSold,
    required this.unitsPerDay,
    required this.stockIds,
    this.currentQuantity,
    this.unitPricePaise,
    this.confidence = .5,
    this.reviewRequired = true,
    this.coverageDays,
    this.expiringWithinLeadUnits = 0,
    this.demand,
    this.projectedExpiryWaste = 0,
    this.safetyBufferUnits = 0,
    this.planningLeadDays = leadDays,
  });

  final String productKey;
  final String name;
  final String salt;
  final String strength;
  final String form;
  final ReorderPriority priority;
  final String reason;

  /// Null means no defensible numerical order can be derived from the records.
  final int? suggestedQuantity;
  final int unitsSold;
  final double unitsPerDay;
  final List<String> stockIds;
  final int? currentQuantity;
  final int? unitPricePaise;

  /// Confidence is operational confidence in the suggested order quantity,
  /// never confidence about a medicine's clinical use.
  final double confidence;

  /// Low-evidence suggestions stay visible but are not auto-selected for an
  /// order. This prevents missing quantity/expiry facts from becoming silent
  /// purchasing assumptions.
  final bool reviewRequired;

  /// Estimated stock coverage using only recorded sales velocity. Null means
  /// the app does not have enough facts to calculate coverage honestly.
  final double? coverageDays;

  /// Known units whose recorded expiry is inside the reorder lead window.
  final int expiringWithinLeadUnits;
  final DailyDemandProfile? demand;
  final int projectedExpiryWaste;
  final int safetyBufferUnits;
  final int planningLeadDays;
  static const leadDays = 7;
  static const targetDays = 30;

  String get title => '$name${strength.isEmpty ? '' : ' · $strength'}';
  String get confidenceLabel => confidence >= .9
      ? 'High-confidence suggestion'
      : confidence >= .75
      ? 'Good-confidence suggestion'
      : 'Review suggestion';
}

class TrackingStats {
  TrackingStats({
    required Iterable<Medicine> medicines,
    required Iterable<SaleEvent> sales,
    required this.range,
    DateTime? today,
    Map<String, Supplier> suppliers = const <String, Supplier>{},
  }) {
    final stockDate = civilDay(today ?? range.end);
    final allRecords = medicines.toList(growable: false);
    final allSales = sales.toList(growable: false);
    final daily = dailyDemandByProduct(
      medicines: allRecords,
      sales: allSales,
      today: stockDate,
    );
    bool usable(Medicine m) => isDispensableOn(m, stockDate);
    final current = <String, List<Medicine>>{};
    for (final medicine in allRecords.where((m) => !m.archived)) {
      current.putIfAbsent(medicine.identity, () => []).add(medicine);
    }

    for (final sale in allSales.where(
      (sale) => range.contains(sale.occurredAt),
    )) {
      recordedSales++;
      unitsSold += sale.quantity;
      if (sale.totalAmountPaise == null) {
        unknownRevenueSales++;
      } else {
        revenuePaise = checkedMoneySum(revenuePaise, sale.totalAmountPaise!);
      }

      // A SaleEvent is an immutable movement snapshot. Never re-key historical
      // movement through the current Medicine row behind stockId: a later
      // pharmacist identity correction must not retroactively manufacture demand
      // for the newly edited medicine or contaminate its reorder velocity.
      final key = sale.productKey;
      final movement = movements.putIfAbsent(
        key,
        () => ProductMovement(
          key: key,
          name: sale.medicineName,
          salt: sale.salt,
          strength: sale.strength,
          form: sale.form,
        ).._periodDays = range.days,
      );
      movement.unitsSold += sale.quantity;
      movement.recordedSales++;
      if (sale.totalAmountPaise == null) {
        movement.unknownRevenueSales++;
      } else {
        movement.knownRevenuePaise = checkedMoneySum(
          movement.knownRevenuePaise,
          sale.totalAmountPaise!,
        );
      }
    }

    final keys = {...current.keys, ...movements.keys};
    for (final key in keys) {
      final records = current[key] ?? const <Medicine>[];
      final hasFutureManufacture = records.any(
        (medicine) =>
            !medicine.sold &&
            medicine.mfg != null &&
            civilDay(medicine.mfg!).isAfter(stockDate),
      );
      final representative =
          records.where(usable).firstOrNull ?? records.firstOrNull;
      if (representative == null) continue;

      final movement = movements.putIfAbsent(
        key,
        () => ProductMovement(
          key: key,
          name: representative.name,
          salt: representative.salt,
          strength: representative.strength,
          form: representative.form,
        ).._periodDays = range.days,
      );

      final profile = daily[key] ?? DailyDemandAccumulator(stockDate).build();
      final movementIdentityConflict = profile.identityConflict;
      movement.identityConflict = movementIdentityConflict;
      movement.demand = profile;

      final active = records.where(usable).toList();
      final known = active.where((m) => m.quantity != null).toList();
      final hasUnknownQuantity = active.any((m) => m.quantity == null);
      final hasUnknownExpiry = active.any(
        (m) => m.quantity != 0 && m.expiry == null,
      );
      final currentQuantity = hasUnknownQuantity
          ? null
          : known.fold<int>(0, (sum, m) => sum + m.quantity!);
      final hasAvailable = active.any(
        (m) => m.quantity == null || (m.quantity ?? 0) > 0,
      );
      movement.currentQuantity = currentQuantity;
      if (hasAvailable) stockedProductKeys.add(key);

      final knownOutOfStock = !hasUnknownQuantity && currentQuantity == 0;
      final outOfStock = !hasAvailable || knownOutOfStock;
      final expiredOnly =
          active.isEmpty &&
          records.any((m) => !m.sold && (m.daysLeft(stockDate) ?? 0) < 0);

      // Planning always uses current daily evidence, independently of the
      // historical analytics range selected elsewhere in the app.
      final velocity = movementIdentityConflict
          ? 0.0
          : profile.planningUnitsPerDay;
      final projection = StockDemandProjection.build(
        medicines: active,
        today: stockDate,
        demand: profile,
      );
      final supplierLeadDays = <int>[];
      for (final medicine in active) {
        final supplier = suppliers[medicine.supplierId.trim()];
        if (supplier == null) continue;
        final configured = supplierPlanningLeadDays(supplier);
        if (configured != null) supplierLeadDays.add(configured);
      }
      final leadDays = supplierLeadDays.isEmpty
          ? ReorderSuggestion.leadDays
          : supplierLeadDays.reduce((left, right) => left > right ? left : right);
      const targetDays = ReorderSuggestion.targetDays;
      final buffer = profile.bufferForDays(leadDays);
      final reorderPoint = profile.demandForDays(leadDays) + buffer;
      final target = profile.demandForDays(targetDays) + buffer;
      final leadWaste = projection?.wasteWithinDays(leadDays) ?? 0.0;
      final targetWaste = projection?.wasteWithinDays(targetDays) ?? 0.0;
      final effectiveQuantity = currentQuantity == null
          ? null
          : currentQuantity - targetWaste;
      final low =
          velocity > 0 &&
          currentQuantity != null &&
          currentQuantity - leadWaste <= reorderPoint + 1e-9;
      final expiryPressure = velocity > 0 && leadWaste > 0 && low;
      final needsReplacement = outOfStock || expiredOnly;
      movement.coverageDays = movementIdentityConflict
          ? null
          : projection?.coverageDays;

      // No fixed ten-unit floor and no reuse of an old SOLD batch as demand.
      // Unknown demand/stock/expiry is a review task, not a fabricated quantity.
      if (!needsReplacement && !low) continue;
      final canCalculate =
          profile.hasEstimate &&
          !movementIdentityConflict &&
          !hasFutureManufacture &&
          !hasUnknownQuantity &&
          !hasUnknownExpiry;
      final rawSuggested = canCalculate && effectiveQuantity != null
          ? ceilStockUnits(target - effectiveQuantity)
          : null;
      final suggested = rawSuggested == null || rawSuggested == 0
          ? null
          : rawSuggested.clamp(1, 100000000);
      final confidence = !canCalculate ? .35 : profile.confidence;
      final reviewRequired =
          !canCalculate ||
          profile.reviewRequired ||
          suggested == null ||
          (rawSuggested ?? 0) > 100000000;
      final coverageDays = movement.coverageDays;

      // Purchase-order cost is an accounting input, not a value Aaris may
      // guess from whichever batch happens to be first in an Iterable. Auto-fill
      // only when all known active batch prices agree. If active stock has no
      // saved price, one unambiguous historical SOLD price may be used. Conflicting
      // evidence intentionally produces null so the pharmacist enters/reviews cost.
      final activePrices = active
          .map((medicine) => medicine.unitPricePaise)
          .whereType<int>()
          .toSet();
      final historicalPrices = records
          .where((medicine) => medicine.sold)
          .map((medicine) => medicine.soldUnitPricePaise)
          .whereType<int>()
          .toSet();
      final price = activePrices.length == 1
          ? activePrices.single
          : activePrices.isEmpty && historicalPrices.length == 1
          ? historicalPrices.single
          : null;
      reorder.add(
        ReorderSuggestion(
          productKey: key,
          name: representative.name,
          salt: representative.salt,
          strength: representative.strength,
          form: representative.form,
          priority: needsReplacement
              ? ReorderPriority.urgent
              : ReorderPriority.soon,
          reason: movementIdentityConflict
              ? needsReplacement
                    ? 'Out of stock · recorded sales identity needs review'
                    : 'Recorded sales identity needs review before reorder'
              : profile.historyNeedsReview
              ? 'Recorded sale dates need review before reorder'
              : hasFutureManufacture && active.isEmpty
              ? 'Manufacturing date needs review before reorder'
              : expiredOnly
              ? 'Only expired stock remains'
              : outOfStock
              ? 'Out of stock'
              : expiryPressure
              ? 'Stock may run short as batches expire within $leadDays days'
              : velocity > 0
              ? 'Low stock · ${velocity.toStringAsFixed(1)} units/day'
              : 'Low stock',
          suggestedQuantity: suggested,
          unitsSold: movementIdentityConflict ? 0 : profile.unitsLast30Days,
          unitsPerDay: velocity,
          stockIds: records.map((m) => m.id).toList(growable: false),
          currentQuantity: currentQuantity,
          unitPricePaise: price,
          confidence: confidence,
          reviewRequired: reviewRequired,
          coverageDays: coverageDays,
          expiringWithinLeadUnits:
              projection?.expiringWithinDays(leadDays) ?? 0,
          demand: profile,
          projectedExpiryWaste: ceilStockUnits(targetWaste),
          safetyBufferUnits: ceilStockUnits(buffer),
          planningLeadDays: leadDays,
        ),
      );
    }
    reorder.sort((a, b) {
      final priority = a.priority.index.compareTo(b.priority.index);
      if (priority != 0) return priority;
      if (a.reviewRequired != b.reviewRequired) {
        return a.reviewRequired ? 1 : -1;
      }
      final confidence = b.confidence.compareTo(a.confidence);
      if (confidence != 0) return confidence;
      final velocity = b.unitsPerDay.compareTo(a.unitsPerDay);
      return velocity != 0 ? velocity : a.name.compareTo(b.name);
    });
  }

  final TrackingRange range;
  int recordedSales = 0;
  int unitsSold = 0;
  int revenuePaise = 0;
  int unknownRevenueSales = 0;
  final Map<String, ProductMovement> movements = {};
  final Set<String> stockedProductKeys = {};
  final List<ReorderSuggestion> reorder = [];

  List<ProductMovement> get fastestMoving {
    final result = movements.values.where((m) => m.unitsSold > 0).toList();
    result.sort((a, b) {
      final units = b.unitsSold.compareTo(a.unitsSold);
      return units != 0 ? units : a.name.compareTo(b.name);
    });
    return result;
  }

  List<ProductMovement> get slowMoving {
    final result = movements.values
        .where(
          (movement) =>
              stockedProductKeys.contains(movement.key) &&
              movement.unitsPerDay < 1 / 7,
        )
        .toList();
    result.sort((a, b) {
      final units = a.unitsSold.compareTo(b.unitsSold);
      if (units != 0) return units;
      final stock = (b.currentQuantity ?? -1).compareTo(
        a.currentQuantity ?? -1,
      );
      return stock != 0 ? stock : a.name.compareTo(b.name);
    });
    return result;
  }
}

/// Shared evidence boundary for ordering and expiry. Immutable sale identities
/// are never relabelled through a subsequently edited stock row. Raw totals stay
/// visible; incompatible identity or impossible chronology disables forecasting.
Map<String, DailyDemandProfile> dailyDemandByProduct({
  required Iterable<Medicine> medicines,
  required Iterable<SaleEvent> sales,
  required DateTime today,
}) {
  final day = civilDay(today);
  final records = {
    for (final m in medicines)
      if (!m.archived) m.id: m,
  };
  final salts = <String, Set<String>>{};
  final accumulators = <String, DailyDemandAccumulator>{};
  for (final m in records.values) {
    accumulators.putIfAbsent(m.identity, () => DailyDemandAccumulator(day));
    final salt = normalize(m.salt);
    if (salt.isNotEmpty) salts.putIfAbsent(m.identity, () => {}).add(salt);
  }
  for (final sale in sales) {
    final saleDay = civilDay(sale.occurredAt);
    if (day.difference(saleDay).inDays > 30) continue;
    final accumulator = accumulators.putIfAbsent(
      sale.productKey,
      () => DailyDemandAccumulator(day),
    );
    final salt = normalize(sale.salt);
    if (!saleDay.isAfter(day) && salt.isNotEmpty) {
      salts.putIfAbsent(sale.productKey, () => {}).add(salt);
    }
    final stock = records[sale.stockId];
    final sameIdentity = stock != null && stock.identity == sale.productKey;
    final invalidChronology =
        sameIdentity &&
        ((stock.mfg != null && saleDay.isBefore(civilDay(stock.mfg!))) ||
            (stock.expiry != null && saleDay.isAfter(civilDay(stock.expiry!))));
    accumulator.add(sale.occurredAt, sale.quantity, valid: !invalidChronology);
  }
  return Map.unmodifiable({
    for (final entry in accumulators.entries)
      entry.key: entry.value.build(
        identityConflict: (salts[entry.key]?.length ?? 0) > 1,
      ),
  });
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
