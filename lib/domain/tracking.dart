import 'dart:math';

import 'medicine.dart';

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
  });

  final String productKey;
  final String name;
  final String salt;
  final String strength;
  final String form;
  final ReorderPriority priority;
  final String reason;
  final int suggestedQuantity;
  final int unitsSold;
  final double unitsPerDay;
  final List<String> stockIds;
  final int? currentQuantity;
  final int? unitPricePaise;
  String get title => '$name${strength.isEmpty ? '' : ' · $strength'}';
}

class TrackingStats {
  TrackingStats({
    required Iterable<Medicine> medicines,
    required Iterable<SaleEvent> sales,
    required this.range,
    DateTime? today,
  }) {
    final stockDate = civilDay(today ?? range.end);
    bool usable(Medicine m) => !m.sold && (m.daysLeft(stockDate) ?? 0) >= 0;
    final current = <String, List<Medicine>>{};
    final byId = <String, Medicine>{};
    for (final medicine in medicines.where((m) => !m.archived)) {
      byId[medicine.id] = medicine;
      current.putIfAbsent(medicine.identity, () => []).add(medicine);
    }

    for (final sale in sales.where((sale) => range.contains(sale.occurredAt))) {
      recordedSales++;
      unitsSold += sale.quantity;
      if (sale.totalAmountPaise == null) {
        unknownRevenueSales++;
      } else {
        revenuePaise = checkedMoneySum(revenuePaise, sale.totalAmountPaise!);
      }
      final record = byId[sale.stockId];
      final key = record?.identity ?? sale.productKey;
      final movement = movements.putIfAbsent(
        key,
        () => ProductMovement(
          key: key,
          name: record?.name ?? sale.medicineName,
          salt: record?.salt ?? sale.salt,
          strength: record?.strength ?? sale.strength,
          form: record?.form ?? sale.form,
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

      final active = records.where(usable).toList();
      final known = active.where((m) => m.quantity != null).toList();
      final hasUnknown = active.any((m) => m.quantity == null);
      final currentQuantity = hasUnknown
          ? null
          : known.fold<int>(0, (sum, m) => sum + m.quantity!);
      final hasAvailable = active.any(
        (m) => m.quantity == null || (m.quantity ?? 0) > 0,
      );
      movement.currentQuantity = currentQuantity;
      if (hasAvailable) stockedProductKeys.add(key);
      final hasSoldEntry = records.any((m) => m.sold);
      final soldOut = !hasAvailable && hasSoldEntry;
      final expiredOnly = active.isEmpty && records.any(
        (m) => !m.sold && (m.daysLeft(stockDate) ?? 0) < 0,
      );
      final needsReplacement = soldOut || expiredOnly;
      final velocity = movement.unitsPerDay;
      final reorderPoint = max(5, (velocity * 7).ceil());
      final target = max(10, max(reorderPoint * 2, (velocity * 30).ceil()));
      final low = currentQuantity != null && currentQuantity <= reorderPoint;
      if (!needsReplacement && !low) continue;

      final previousStock = records
          .map((m) => m.soldQuantity ?? 0)
          .fold<int>(0, max);
      final suggested = needsReplacement
          ? max(1, max(target, previousStock))
          : max(1, target - (currentQuantity ?? 0));
      final price =
          active
              .where((m) => m.unitPricePaise != null)
              .firstOrNull
              ?.unitPricePaise ??
          records
              .where((m) => m.soldUnitPricePaise != null)
              .firstOrNull
              ?.soldUnitPricePaise;
      reorder.add(
        ReorderSuggestion(
          productKey: key,
          name: representative.name,
          salt: representative.salt,
          strength: representative.strength,
          form: representative.form,
          priority: needsReplacement ? ReorderPriority.urgent : ReorderPriority.soon,
          reason: expiredOnly
              ? 'Only expired stock remains'
              : soldOut
              ? 'Out of stock'
              : velocity > 0
              ? 'Low stock · ${velocity.toStringAsFixed(1)} units/day'
              : 'Low stock',
          suggestedQuantity: suggested,
          unitsSold: movement.unitsSold,
          unitsPerDay: velocity,
          stockIds: records.map((m) => m.id).toList(growable: false),
          currentQuantity: currentQuantity,
          unitPricePaise: price,
        ),
      );
    }
    reorder.sort((a, b) {
      final priority = a.priority.index.compareTo(b.priority.index);
      if (priority != 0) return priority;
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

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
