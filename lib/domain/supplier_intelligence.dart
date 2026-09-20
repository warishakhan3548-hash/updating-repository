import 'medicine.dart';
import 'supplier.dart';
import 'tracking.dart';

class SupplierProductProfile {
  const SupplierProductProfile({
    required this.productKey,
    required this.supplier,
    required this.samples,
    required this.medianRemainingShelfLifeDays,
    required this.medianUsableShelfLifeDays,
    required this.medianUnitCostPaise,
    required this.planningLeadDays,
  });

  final String productKey;
  final Supplier supplier;
  final int samples;
  final int medianRemainingShelfLifeDays;
  final int medianUsableShelfLifeDays;
  final int? medianUnitCostPaise;
  final int? planningLeadDays;
}

class SupplierPurchaseAdvice {
  const SupplierPurchaseAdvice({
    required this.productKey,
    required this.supplierId,
    required this.supplierName,
    required this.reason,
    required this.samples,
  });

  final String productKey;
  final String supplierId;
  final String supplierName;
  final String reason;
  final int samples;
}

/// Learns only from durable lot intake facts that Aaris itself recorded.
///
/// No supplier is ranked from names, medicine knowledge or missing facts. A
/// product needs at least two observed suppliers and two independent receipt
/// observations per compared supplier before a recommendation is emitted.
Map<String, SupplierPurchaseAdvice> buildSupplierPurchaseAdvice({
  required Iterable<Medicine> medicines,
  required Map<String, Supplier> suppliers,
  required Iterable<ReorderSuggestion> reorder,
  required DateTime today,
}) {
  final wanted = reorder.map((item) => item.productKey).toSet();
  if (wanted.isEmpty || suppliers.length < 2) {
    return const <String, SupplierPurchaseAdvice>{};
  }
  final day = civilDay(today);
  final cutoff = day.subtract(const Duration(days: 730));
  final observations = <String, List<StockIntakeEvidence>>{};
  final seen = <String>{};

  for (final medicine in medicines) {
    for (final evidence in medicine.intakeHistory) {
      if (!wanted.contains(evidence.productKey) ||
          !suppliers.containsKey(evidence.supplierId)) {
        continue;
      }
      final receivedDay = civilDay(evidence.receivedAt);
      if (receivedDay.isBefore(cutoff) || receivedDay.isAfter(day)) continue;
      final dedupe = <String>[
        evidence.productKey,
        evidence.supplierId,
        dateText(receivedDay),
        evidence.batchNumber,
        dateText(evidence.expiry),
        evidence.unitCostPaise?.toString() ?? '',
      ].join('|');
      if (!seen.add(dedupe)) continue;
      final key = '${evidence.productKey}\u0000${evidence.supplierId}';
      observations.putIfAbsent(key, () => <StockIntakeEvidence>[]).add(evidence);
    }
  }

  final byProduct = <String, List<SupplierProductProfile>>{};
  for (final entry in observations.entries) {
    final split = entry.key.split('\u0000');
    if (split.length != 2) continue;
    final productKey = split[0];
    final supplier = suppliers[split[1]];
    if (supplier == null) continue;
    final samples = entry.value;
    if (samples.length < 2) continue;
    final remaining = samples
        .map((item) => item.remainingShelfLifeDays)
        .where((days) => days >= 0)
        .toList(growable: false);
    if (remaining.length < 2) continue;
    final usable = remaining
        .map((days) => days - supplier.returnBeforeExpiryDays)
        .map((days) => days < 0 ? 0 : days)
        .toList(growable: false);
    final costs = samples
        .map((item) => item.unitCostPaise)
        .whereType<int>()
        .toList(growable: false);
    final profile = SupplierProductProfile(
      productKey: productKey,
      supplier: supplier,
      samples: remaining.length,
      medianRemainingShelfLifeDays: _median(remaining),
      medianUsableShelfLifeDays: _median(usable),
      medianUnitCostPaise: costs.length >= 2 ? _median(costs) : null,
      planningLeadDays: supplierPlanningLeadDays(supplier),
    );
    byProduct.putIfAbsent(productKey, () => <SupplierProductProfile>[]).add(profile);
  }

  final result = <String, SupplierPurchaseAdvice>{};
  for (final entry in byProduct.entries) {
    final profiles = entry.value;
    if (profiles.length < 2) continue;
    profiles.sort(_compareProfiles);
    final best = profiles[0];
    final runner = profiles[1];
    final shelfAdvantage =
        best.medianUsableShelfLifeDays - runner.medianUsableShelfLifeDays;
    final leadAdvantage = best.planningLeadDays != null &&
            runner.planningLeadDays != null
        ? runner.planningLeadDays! - best.planningLeadDays!
        : 0;
    final costAdvantage = best.medianUnitCostPaise != null &&
            runner.medianUnitCostPaise != null &&
            runner.medianUnitCostPaise! > 0
        ? (runner.medianUnitCostPaise! - best.medianUnitCostPaise!) /
            runner.medianUnitCostPaise!
        : 0.0;
    final comparableShelf =
        best.medianUsableShelfLifeDays + 14 >= runner.medianUsableShelfLifeDays;
    final meaningful = shelfAdvantage >= 30 ||
        (leadAdvantage >= 2 && comparableShelf) ||
        (costAdvantage >= .05 && comparableShelf);
    if (!meaningful) continue;

    final cues = <String>[
      '${best.samples} verified intake observations',
      'usable shelf-life median ${best.medianUsableShelfLifeDays} दिन',
      '${runner.supplier.name}: ${runner.medianUsableShelfLifeDays} दिन',
      if (best.planningLeadDays != null)
        'lead time ${best.planningLeadDays} दिन',
      if (best.medianUnitCostPaise != null &&
          runner.medianUnitCostPaise != null)
        'median cost ${money(best.medianUnitCostPaise!)} vs ${money(runner.medianUnitCostPaise!)}',
    ];
    result[entry.key] = SupplierPurchaseAdvice(
      productKey: entry.key,
      supplierId: best.supplier.id,
      supplierName: best.supplier.name,
      samples: best.samples,
      reason: '${best.supplier.name} का recent evidence बेहतर दिख रहा है · ${cues.join(' · ')}',
    );
  }
  return Map<String, SupplierPurchaseAdvice>.unmodifiable(result);
}

int _compareProfiles(SupplierProductProfile left, SupplierProductProfile right) {
  final shelf = right.medianUsableShelfLifeDays.compareTo(
    left.medianUsableShelfLifeDays,
  );
  if (shelf != 0) return shelf;
  final leftLead = left.planningLeadDays ?? 1 << 20;
  final rightLead = right.planningLeadDays ?? 1 << 20;
  final lead = leftLead.compareTo(rightLead);
  if (lead != 0) return lead;
  final leftCost = left.medianUnitCostPaise ?? maxExactPaise;
  final rightCost = right.medianUnitCostPaise ?? maxExactPaise;
  final cost = leftCost.compareTo(rightCost);
  if (cost != 0) return cost;
  final samples = right.samples.compareTo(left.samples);
  return samples != 0
      ? samples
      : left.supplier.name.compareTo(right.supplier.name);
}

int _median(List<int> source) {
  final values = List<int>.from(source)..sort();
  final middle = values.length ~/ 2;
  if (values.length.isOdd) return values[middle];
  return ((values[middle - 1] + values[middle]) / 2).round();
}
