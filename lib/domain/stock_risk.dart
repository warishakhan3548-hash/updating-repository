import 'dart:math' as math;

import 'medicine.dart';
import 'tracking.dart';

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

    final evidence = <String, _VelocityEvidence>{};
    final start30 = day.subtract(const Duration(days: 29));
    final start7 = day.subtract(const Duration(days: 6));
    for (final sale in sales) {
      final saleDay = civilDay(sale.occurredAt);
      if (saleDay.isBefore(start30) || saleDay.isAfter(day)) continue;

      // SaleEvent stores an immutable product snapshot. Always attribute the
      // historical movement to that snapshot identity, never to the current
      // Medicine row behind stockId. A later pharmacist correction may change
      // name/strength/form on the live row; retroactively relabelling old sales
      // would otherwise manufacture false demand and unsafe expiry forecasts.
      final item = evidence.putIfAbsent(sale.productKey, _VelocityEvidence.new);
      item.units30 += sale.quantity;
      item.events30++;
      final salt = normalize(sale.salt);
      if (salt.isNotEmpty) item.salts.add(salt);
      if (item.firstDay == null || saleDay.isBefore(item.firstDay!)) {
        item.firstDay = saleDay;
      }
      if (!saleDay.isBefore(start7)) {
        item.units7 += sale.quantity;
      }
    }

    final risks = <ExpiryWasteRisk>[];
    for (final entry in groups.entries) {
      final rows = entry.value;

      // Medicine identity intentionally excludes optional salt so ordinary
      // search can still find incomplete records. Forecasting is stricter: two
      // different known salts under the same name/strength/form make product
      // aggregation unsafe, so Needs Attention must resolve those facts first.
      final currentSalts = rows
          .map((medicine) => normalize(medicine.salt))
          .where((salt) => salt.isNotEmpty)
          .toSet();
      if (currentSalts.length > 1) continue;

      // Quantity or expiry uncertainty makes a FEFO stock-consumption forecast
      // unsafe. Existing attention checks surface those missing facts instead of
      // this engine inventing a denominator or an expiry order.
      if (rows.any((medicine) => medicine.quantity == null)) continue;
      final positive = rows
          .where((medicine) => medicine.quantity! > 0)
          .toList();
      if (positive.isEmpty ||
          positive.any((medicine) => medicine.expiry == null)) {
        continue;
      }

      final movement = evidence[entry.key];
      if (movement == null ||
          movement.events30 < 2 ||
          movement.units30 <= 0 ||
          movement.firstDay == null) {
        continue;
      }

      // Historical sale snapshots are equally authoritative evidence. If their
      // known salt facts conflict with each other or with the current product,
      // do not merge movement across potentially different medicines. Missing
      // salt remains unknown rather than being treated as a contradiction.
      if (movement.salts.length > 1) continue;
      if (currentSalts.isNotEmpty &&
          movement.salts.isNotEmpty &&
          currentSalts.single != movement.salts.single) {
        continue;
      }

      // A newly recorded sales history must not be diluted over a full 30 days.
      // Clamp the observed denominator to 7..30 days, then use the faster of
      // recent-seven-day and observed-period demand. This deliberately biases
      // against false expiry-waste alarms when recent demand is accelerating.
      final observedDays = math.min(
        30,
        math.max(7, day.difference(movement.firstDay!).inDays + 1),
      );
      final periodVelocity = movement.units30 / observedDays;
      final recentVelocity = movement.units7 / 7.0;
      final planningVelocity = math.max(periodVelocity, recentVelocity);
      if (planningVelocity <= 0) continue;

      positive.sort((a, b) {
        final expiry = a.expiry!.compareTo(b.expiry!);
        if (expiry != 0) return expiry;
        final batch = normalize(a.batchNumber).compareTo(
          normalize(b.batchNumber),
        );
        return batch != 0 ? batch : a.id.compareTo(b.id);
      });

      // Track only demand actually allocated to earlier FEFO batches. A surplus
      // in an early batch expires and must not incorrectly consume demand that
      // occurs after that batch is gone. This keeps later-batch risk from being
      // overstated when an earlier lot is itself projected to have leftovers.
      var projectedConsumedEarlier = 0;
      for (final medicine in positive) {
        final days = medicine.daysLeft(day)!;
        if (days > maxHorizonDays) break;
        final quantity = medicine.quantity!;

        // Expiry is inclusive, so a batch expiring today still has one possible
        // dispensing day. Project only recorded operational demand; never infer
        // any clinical need or future prescription volume.
        final horizonDays = math.max(1, days + 1);
        final expectedDemandByExpiry = (planningVelocity * horizonDays).ceil();
        final demandAvailableForBatch = math.max(
          0,
          expectedDemandByExpiry - projectedConsumedEarlier,
        );
        final projectedConsumed = math.min(quantity, demandAvailableForBatch);
        final atRisk = quantity - projectedConsumed;
        projectedConsumedEarlier += projectedConsumed;

        final minimumSignal = math.max(2, (quantity * .20).ceil());
        if (atRisk < minimumSignal) continue;

        final confidence = movement.events30 >= 6 && observedDays >= 21
            ? .92
            : movement.events30 >= 3
            ? .78
            : .62;
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
            daysUntilExpiry: days,
            batchQuantity: quantity,
            atRiskUnits: atRisk,
            planningUnitsPerDay: planningVelocity,
            saleEvents: movement.events30,
            observedDays: observedDays,
            confidence: confidence,
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

class _VelocityEvidence {
  int units30 = 0;
  int events30 = 0;
  int units7 = 0;
  final Set<String> salts = <String>{};
  DateTime? firstDay;
}
