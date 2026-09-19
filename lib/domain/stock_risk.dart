import 'dart:math' as math;

import 'medicine.dart';
import 'tracking.dart';
import 'stock_projection.dart';

class ExpiryWasteRisk {
  const ExpiryWasteRisk({
    required this.stockId,
    required this.productKey,
    required this.name,
    required this.strength,
    required this.form,
    required this.batchNumber,
    required this.address,
    required this.expiry,
    required this.daysUntilExpiry,
    required this.batchQuantity,
    required this.atRiskUnits,
    required this.planningUnitsPerDay,
    required this.saleEvents,
    required this.observedDays,
    required this.confidence,
  });

  final String stockId;
  final String productKey;
  final String name;
  final String strength;
  final String form;
  final String batchNumber;
  final String address;
  final DateTime expiry;
  final int daysUntilExpiry;
  final int batchQuantity;
  final int atRiskUnits;
  final double planningUnitsPerDay;
  final int saleEvents;
  final int observedDays;
  final double confidence;

  String get title => '$name${strength.isEmpty ? '' : ' · $strength'}';
  double get atRiskFraction =>
      batchQuantity == 0 ? 0 : atRiskUnits / batchQuantity;

  String get stockCue {
    final parts = <String>[
      if (batchNumber.trim().isNotEmpty) 'Batch ${batchNumber.trim()}',
      if (address.trim().isNotEmpty) address.trim(),
    ];
    return parts.isEmpty ? 'Exact stock row' : parts.join(' · ');
  }

  String get confidenceLabel => confidence >= .9
      ? 'high evidence'
      : confidence >= .75
      ? 'good evidence'
      : 'limited evidence';
}

class PharmacyStockRiskReport {
  PharmacyStockRiskReport._(List<ExpiryWasteRisk> risks)
    : expiryWaste = List.unmodifiable(risks);

  factory PharmacyStockRiskReport.build({
    required Iterable<Medicine> medicines,
    required Iterable<SaleEvent> sales,
    required DateTime today,
    int maxHorizonDays = 60,
  }) {
    if (maxHorizonDays < 1 || maxHorizonDays > 730) {
      throw const FormatException(
        'Expiry risk horizon must be between 1 and 730 days.',
      );
    }

    final day = civilDay(today);
    final allRecords = medicines.toList(growable: false);
    final groups = <String, List<Medicine>>{};

    for (final medicine in allRecords) {
      if (medicine.archived || medicine.sold || medicine.quantity == 0) {
        continue;
      }
      if (medicine.mfg != null && civilDay(medicine.mfg!).isAfter(day)) {
        continue;
      }
      final days = medicine.daysLeft(day);
      if (days != null && days < 0) continue;
      groups.putIfAbsent(medicine.identity, () => <Medicine>[]).add(medicine);
    }

    final evidence = dailyDemandByProduct(
      medicines: allRecords,
      sales: sales,
      today: day,
    );
    final risks = <ExpiryWasteRisk>[];
    for (final entry in groups.entries) {
      final demand = evidence[entry.key];
      // Two distinct completed selling days are the minimum for an indicative
      // waste estimate. Many receipts on one day remain a single day's evidence.
      if (demand == null || !demand.hasEstimate || demand.sellingDays < 2)
        continue;
      final projection = StockDemandProjection.build(
        medicines: entry.value,
        today: day,
        demand: demand,
      );
      if (projection == null) continue;
      for (final batch in projection.batches) {
        if (batch.daysUntilExpiry > maxHorizonDays) break;
        final medicine = batch.stock;
        final quantity = medicine.quantity!;
        final atRisk = batch.atRiskUnits;
        final minimumSignal = math.max(2, (quantity * .20).ceil());
        if (atRisk < minimumSignal) continue;
        risks.add(
          ExpiryWasteRisk(
            stockId: medicine.id,
            productKey: medicine.identity,
            name: medicine.name,
            strength: medicine.strength,
            form: medicine.form,
            batchNumber: medicine.batchNumber,
            address: medicine.address,
            expiry: medicine.expiry!,
            daysUntilExpiry: batch.daysUntilExpiry,
            batchQuantity: quantity,
            atRiskUnits: atRisk,
            planningUnitsPerDay: demand.planningUnitsPerDay,
            saleEvents: demand.recordedSales,
            observedDays: demand.observedDays,
            confidence: demand.confidence,
          ),
        );
      }
    }

    risks.sort((a, b) {
      final expiry = a.daysUntilExpiry.compareTo(b.daysUntilExpiry);
      if (expiry != 0) return expiry;
      final units = b.atRiskUnits.compareTo(a.atRiskUnits);
      if (units != 0) return units;
      return a.title.compareTo(b.title);
    });
    return PharmacyStockRiskReport._(risks);
  }

  final List<ExpiryWasteRisk> expiryWaste;
  bool get isEmpty => expiryWaste.isEmpty;
}
