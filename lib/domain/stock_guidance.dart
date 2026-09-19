import 'attention.dart';
import 'daily_demand.dart';
import 'inventory.dart';
import 'medicine.dart';
import 'operations_plan.dart';
import 'supplier.dart';
import 'tracking.dart';

enum StockTaskGroup { urgent, order, supplier, details, movement }

/// Short shop-floor instructions derived from the existing verified work plan.
/// Quantity always means the inventory's recorded unit, never an inferred strip
/// or tablet conversion. Presentation cannot remove a planning prerequisite.
class StockGuidance {
  const StockGuidance({
    required this.key,
    required this.title,
    required this.action,
    required this.reason,
    required this.group,
    required this.stockIds,
    this.step,
    this.demand,
    this.supplierId,
  });

  final String key, title, action, reason;
  final StockTaskGroup group;
  final List<String> stockIds;
  final OperationsPlanStep? step;
  final DailyDemandProfile? demand;
  final String? supplierId;

  bool get blocked => step?.blocked ?? false;
  bool get critical => step?.item.severity == AttentionSeverity.critical;

  factory StockGuidance.fromStep(
    OperationsPlanStep step, {
    required Map<String, Medicine> records,
    required Map<String, ReorderSuggestion> orders,
    required DateTime today,
    int salesDays = 30,
    Map<String, DailyDemandProfile> dailyDemand = const {},
  }) {
    final item = step.item;
    final stock = item.stockIds
        .map((id) => records[id])
        .whereType<Medicine>()
        .where((record) => !record.archived)
        .toList(growable: false);
    final order = item.isReorder ? orders[item.productKey] : null;
    final titles = stock.map((record) => record.title).toSet();
    final title =
        order?.title ??
        (titles.length == 1
            ? titles.single
            : titles.isEmpty
            ? 'दवा की जानकारी जाँचें'
            : '${titles.first} + ${titles.length - 1} दवाएँ');
    final record = stock.length == 1 ? stock.single : null;
    final day = record?.daysLeft(civilDay(today));
    var action = stockActionLabel(item.kind);
    var reason = switch (item.kind) {
      AttentionKind.expiredStock => 'Expiry निकल चुकी है',
      AttentionKind.shortExpiry =>
        day == null
            ? 'Expiry पास है'
            : day == 0
            ? 'आज आखिरी दिन है'
            : '$day दिन में expiry',
      AttentionKind.expiryWastePressure =>
        item.expiryRisk == null
            ? 'Expiry से पहले स्टॉक बच सकता है'
            : '${item.expiryRisk!.daysUntilExpiry} दिन में expiry · लगभग ${item.expiryRisk!.atRiskUnits} यूनिट बच सकती हैं',
      AttentionKind.unknownExpiry => 'पैक पर लिखी तारीख दर्ज करें',
      AttentionKind.unknownQuantity => 'बचा हुआ स्टॉक दर्ज नहीं है',
      AttentionKind.zeroQuantityMismatch => 'स्टॉक 0 है · स्थिति जाँचें',
      AttentionKind.missingStockLocation => 'रैक या शेल्फ का नाम लिखें',
      AttentionKind.barcodeConflict => 'एक barcode पर अलग दवाएँ हैं',
      AttentionKind.conflictingLotFacts => 'एक ही पैक की जानकारी अलग है',
      AttentionKind.possibleDuplicateBatch => 'एक स्टॉक दो बार दर्ज हो सकता है',
      AttentionKind.soldAuditGap => 'पुरानी बिकी मात्रा दर्ज नहीं है',
      AttentionKind.staleSoldMetadata => 'बिक्री और बचे स्टॉक में अंतर है',
      AttentionKind.futureSaleHistory => 'बिक्री में आगे की तारीख दर्ज है',
      AttentionKind.saleLifecycleConflict =>
        'बिक्री और पैक की तारीखें नहीं मिलतीं',
      AttentionKind.futureManufactureDate => 'बनने की तारीख आगे की है',
      AttentionKind.urgentReorder || AttentionKind.reorderReview =>
        order == null
            ? 'मँगाने से पहले स्टॉक जाँचें'
            : reorderSummary(order, salesDays),
    };
    if (order != null && !step.blocked) {
      action = order.reviewRequired || order.suggestedQuantity == null
          ? 'मँगाने की मात्रा जाँचें'
          : '${order.suggestedQuantity} यूनिट मँगाएँ';
    }
    if (step.blocked) {
      action = 'पहले ${stockActionLabel(step.prerequisites.first.kind)}';
      reason = item.isReorder ? 'ऑर्डर से पहले जानकारी पूरी करें' : reason;
    } else if (!item.isReorder && record?.quantity != null) {
      reason = '${record!.quantity} यूनिट · $reason';
    } else if (!item.isReorder && stock.length > 1) {
      reason = '${stock.length} स्टॉक entries · $reason';
    }
    return StockGuidance(
      key: item.key,
      title: title,
      action: action,
      reason: reason,
      group: item.isReorder
          ? StockTaskGroup.order
          : item.severity == AttentionSeverity.critical ||
                item.kind == AttentionKind.shortExpiry ||
                item.kind == AttentionKind.expiryWastePressure
          ? StockTaskGroup.urgent
          : StockTaskGroup.details,
      stockIds: item.stockIds,
      step: step,
      demand:
          order?.demand ??
          (item.kind == AttentionKind.expiryWastePressure
              ? dailyDemand[item.productKey]
              : null),
    );
  }
}

List<StockGuidance> supplierReturnGuidance({
  required Iterable<SupplierReturnCandidate> candidates,
}) {
  final result = <StockGuidance>[];
  for (final candidate in candidates) {
    final medicine = candidate.medicine;
    final supplier = candidate.supplier;
    final cues = <String>[
      if (medicine.quantity != null) '${medicine.quantity} यूनिट',
      '${candidate.daysLeft} दिन में expiry',
      if (medicine.batchNumber.trim().isNotEmpty)
        'Batch ${medicine.batchNumber.trim()}',
      if (medicine.address.trim().isNotEmpty) medicine.address.trim(),
    ];
    result.add(
      StockGuidance(
        key: 'supplier-return:${supplier.id}:${medicine.id}',
        title: medicine.title,
        action: medicine.quantity == null
            ? 'वापसी से पहले stock count करें'
            : '${supplier.name} को वापसी तैयार करें',
        reason:
            "${cues.join(' · ')} · supplier window ${supplier.returnBeforeExpiryDays} दिन",
        group: StockTaskGroup.supplier,
        stockIds: List.unmodifiable(<String>[medicine.id]),
        supplierId: supplier.id,
      ),
    );
  }
  result.sort((a, b) {
    final supplier = (a.supplierId ?? '').compareTo(b.supplierId ?? '');
    if (supplier != 0) return supplier;
    return a.title.compareTo(b.title);
  });
  return List.unmodifiable(result);
}

String stockActionLabel(AttentionKind kind) => switch (kind) {
  AttentionKind.expiredStock => 'अलग रखें · न बेचें',
  AttentionKind.shortExpiry => 'पहले यह स्टॉक निकालें',
  AttentionKind.expiryWastePressure => 'बचा स्टॉक / वापसी जाँचें',
  AttentionKind.unknownExpiry => 'Expiry जोड़ें',
  AttentionKind.unknownQuantity => 'स्टॉक गिनें',
  AttentionKind.zeroQuantityMismatch => 'बचा स्टॉक जाँचें',
  AttentionKind.missingStockLocation => 'रैक / शेल्फ लिखें',
  AttentionKind.barcodeConflict => 'Barcode जाँचें',
  AttentionKind.conflictingLotFacts => 'पैक की जानकारी जाँचें',
  AttentionKind.possibleDuplicateBatch => 'दोहरी entry जाँचें',
  AttentionKind.soldAuditGap ||
  AttentionKind.staleSoldMetadata => 'पुरानी बिक्री जाँचें',
  AttentionKind.futureSaleHistory => 'बिक्री की तारीख जाँचें',
  AttentionKind.saleLifecycleConflict => 'पैक और बिक्री जाँचें',
  AttentionKind.futureManufactureDate => 'MFG तारीख जाँचें',
  AttentionKind.urgentReorder || AttentionKind.reorderReview => 'ऑर्डर जाँचें',
};

String reorderSummary(ReorderSuggestion order, int salesDays) {
  final demand = order.demand;
  final stock = order.currentQuantity == null
      ? 'स्टॉक गिनना बाकी है'
      : '${order.currentQuantity} यूनिट बचीं';
  if (demand == null)
    return [
      stock,
      order.unitsSold > 0
          ? '$salesDays दिन में ${order.unitsSold} बिक्री दर्ज'
          : 'बिक्री का पर्याप्त रिकॉर्ड नहीं',
    ].join(' · ');
  return '$stock${order.coverageDays == null ? '' : ' · करीब ${order.coverageDays!.ceil()} दिन'}\n${dailyDemandSummary(demand)}';
}

String dailyDemandSummary(DailyDemandProfile demand) => [
  if (demand.hasEstimate)
    'रफ्तार ≈${demand.planningUnitsPerDay.toStringAsFixed(demand.planningUnitsPerDay < .1 ? 2 : 1)} यूनिट/दिन',
  '30 दिन में ${demand.unitsLast30Days} बिक्री दर्ज',
].join(' · ');

String demandTrendLabel(DailyDemandProfile demand) {
  if (!demand.usableHistory) return 'बिक्री की जानकारी जाँचें';
  if (demand.recentWeekUnits == 0) return '7 दिन से बिक्री दर्ज नहीं';
  if (demand.variableSales) return 'बिक्री में बड़ा उतार-चढ़ाव';
  return switch (demand.trend) {
    DemandTrend.rising => 'बिक्री बढ़ रही है',
    DemandTrend.falling => 'बिक्री धीमी हुई है',
    DemandTrend.steady => 'बिक्री की रफ्तार स्थिर है',
    DemandTrend.insufficient => 'तुलना के लिए और रिकॉर्ड चाहिए',
  };
}

/// Movement reminders use recorded daily evidence; an unlogged sale is unknown.
/// A firm pause needs supported history and >=30 days of usable stock coverage.
/// Products already needing an order or fact repair keep their existing task.
List<StockGuidance> stockMovementGuidance({
  required TrackingStats tracking,
  required Map<String, Medicine> records,
  required PharmacyOperationsPlan plan,
  required DateTime today,
}) {
  final excluded = <String>{
    for (final step in plan.steps)
      if (step.item.productKey != null) step.item.productKey!,
    for (final step in plan.steps)
      for (final id in step.item.stockIds)
        if (records[id] != null) records[id]!.identity,
  };
  final byProduct = <String, List<Medicine>>{};
  for (final record in records.values) {
    if (!record.archived && !record.sold) {
      byProduct.putIfAbsent(record.identity, () => []).add(record);
    }
  }
  final result = <StockGuidance>[];
  for (final movement in tracking.movements.values) {
    if (excluded.contains(movement.key) || movement.identityConflict) continue;
    final stock = byProduct[movement.key] ?? const <Medicine>[];
    if (stock.isEmpty ||
        stock.any(
          (record) =>
              record.quantity == null ||
              record.expiry == null ||
              !isDispensableOn(record, today),
        )) {
      continue;
    }
    final quantity = movement.currentQuantity;
    if (quantity == null || quantity <= 0) continue;
    final demand = movement.demand;
    if (demand == null || !demand.usableHistory) continue;
    final enoughStock =
        !demand.reviewRequired &&
        (movement.coverageDays ?? 0) >= ReorderSuggestion.targetDays;
    final action = enoughStock
        ? 'अभी और न मँगाएँ'
        : demand.reviewRequired
        ? 'ऑर्डर से पहले बिक्री जाँचें'
        : demand.trend == DemandTrend.rising
        ? 'बिक्री बढ़ी है · स्टॉक देखें'
        : demand.trend == DemandTrend.falling
        ? 'बिक्री धीमी है · ऑर्डर जाँचें'
        : 'फिलहाल स्टॉक पर्याप्त है';
    result.add(
      StockGuidance(
        key: 'movement:${movement.key}',
        title: movement.title,
        action: action,
        reason:
            '$quantity यूनिट बचीं${movement.coverageDays == null ? '' : ' · करीब ${movement.coverageDays!.ceil()} दिन'}\n${dailyDemandSummary(demand)}',
        group: StockTaskGroup.movement,
        stockIds: List.unmodifiable(stock.map((record) => record.id)),
        demand: demand,
      ),
    );
  }
  result.sort((a, b) {
    final velocity = b.demand!.planningUnitsPerDay.compareTo(
      a.demand!.planningUnitsPerDay,
    );
    return velocity != 0 ? velocity : a.title.compareTo(b.title);
  });
  return result;
}
