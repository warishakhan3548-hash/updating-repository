import 'medicine.dart';
import 'tracking.dart';

class SoldMedicineDemand {
  SoldMedicineDemand({required this.key, required this.name});

  final String key;
  final String name;
  int unitsSold = 0;
  int recordedSales = 0;
  int knownSalesValuePaise = 0;
  int unknownValueSales = 0;

  double demandShare(int totalUnitsSold) =>
      totalUnitsSold <= 0 ? 0 : unitsSold / totalUnitsSold;
}

String _finalSaleWitness(String stockId, DateTime occurredAt) =>
    '$stockId|${occurredAt.toUtc().microsecondsSinceEpoch}';

/// Deterministic, all-time sales analytics derived from the pharmacy's own
/// recorded sale events plus explicit SOLD transitions. AI never invents a
/// demand percentage or sale value here.
class SalesOverview {
  SalesOverview(
    Iterable<SaleEvent> sales, {
    Iterable<Medicine> medicines = const <Medicine>[],
    Iterable<Map<String, dynamic>> events = const <Map<String, dynamic>>[],
  }) {
    final saleList = sales.toList(growable: false);
    final medicineList = medicines.toList(growable: false);
    final medicineById = <String, Medicine>{
      for (final medicine in medicineList) medicine.id: medicine,
    };

    // Build the SOLD/final-sale witness set during the one mandatory sales pass.
    // The previous fallback reconciliation scanned every sale again for every
    // currently SOLD medicine, turning a large pharmacy snapshot into O(M×S)
    // work. Exact stock ID + sale instant is enough to preserve the same
    // duplicate-suppression rule with O(1) lookup per SOLD row.
    final recordedSaleWitnesses = <String>{};
    for (final sale in saleList) {
      recordedSaleWitnesses.add(_finalSaleWitness(sale.stockId, sale.occurredAt));
      final knownValue =
          sale.totalAmountPaise ??
          (sale.savedUnitPricePaise == null
              ? null
              : stockValue(sale.quantity, sale.savedUnitPricePaise!));
      _record(
        name: sale.medicineName,
        units: sale.quantity,
        knownValuePaise: knownValue,
      );
    }

    // Legacy direct "Mark stock SOLD" actions can predate the durable
    // SaleEvent path. Unknown-quantity confirmations also cannot truthfully
    // create a unit-based sale. The bounded Activity stream remains a
    // compatibility witness only: fold legacy transitions when a positive unit
    // count is actually known, and never invent one unit for missing/zero stock.
    final directSoldStockIds = <String>{};
    for (final event in events) {
      // Undo keeps the original event for audit history. It must not keep
      // contributing phantom demand or value after its stock transition and
      // aggregate totals have been reversed.
      if (event['undone'] == true) continue;
      final soldValue = event['soldValue'];
      final unknownSold = event['unknownSold'];
      final hasSoldTransition =
          (soldValue is int && soldValue > 0) ||
          (unknownSold is int && unknownSold > 0);
      if (!hasSoldTransition) continue;

      // recordSale(markSoldOut: true) already writes a real SaleEvent in the
      // same mutation. Do not synthesize a second sale for that transition.
      final salesBefore = event['salesBefore'];
      if (salesBefore is Map &&
          salesBefore.values.any((value) => value == null)) {
        continue;
      }

      final beforeRaw = event['before'];
      if (beforeRaw is! Map || beforeRaw.length != 1) continue;
      final beforeValue = beforeRaw.values.single;
      if (beforeValue is! Map) continue;

      Medicine before;
      try {
        before = Medicine.fromJson(Map<String, dynamic>.from(beforeValue));
      } catch (_) {
        continue;
      }
      if (before.sold) continue;

      final isLatestDirectTransition = directSoldStockIds.add(before.id);
      final current = medicineById[before.id];
      final useCurrentSoldSnapshot =
          isLatestDirectTransition && current != null && current.sold;

      final units = useCurrentSoldSnapshot
          ? _knownPositiveUnits(current.soldQuantity)
          : _knownPositiveUnits(before.quantity);
      if (units == null) continue;
      final name = useCurrentSoldSnapshot ? current.name : before.name;

      // Persistence stores SOLD value as the transaction aggregate
      // (captured sold quantity × saved unit price). _record expects that same
      // aggregate, so converting it back to a unit price would undercount every
      // direct SOLD transition with more than one unit.
      final amount =
          soldValue is int && soldValue > 0 && soldValue <= maxExactPaise
          ? soldValue
          : null;

      _record(name: name, units: units, knownValuePaise: amount);
    }

    // Backups or very old databases can contain a currently SOLD medicine even
    // when its transition event is unavailable. Count it once as a safe
    // fallback, unless a real final-sale event already represents that SOLD.
    for (final medicine in medicineList.where((medicine) => medicine.sold)) {
      if (directSoldStockIds.contains(medicine.id)) continue;
      if (_hasRecordedFinalSale(medicine, recordedSaleWitnesses)) continue;
      final units = _knownPositiveUnits(medicine.soldQuantity);
      if (units == null) continue;
      final unitPrice =
          medicine.soldUnitPricePaise ?? medicine.unitPricePaise;
      int? amount;
      if (unitPrice != null) {
        try {
          amount = stockValue(units, unitPrice);
        } on FormatException {
          // Legacy/restored data can predate today's aggregate validation.
          // Keep the sale visible, but do not let an unsafe value crash stats.
        }
      }
      _record(name: medicine.name, units: units, knownValuePaise: amount);
    }
  }

  int recordedSales = 0;
  int totalUnitsSold = 0;
  int salesValuePaise = 0;
  int unknownValueSales = 0;
  final Map<String, SoldMedicineDemand> _byMedicine = {};
  SoldMedicineDemand? _topDemandCache;
  bool _topDemandResolved = false;
  List<SoldMedicineDemand>? _rankedCache;

  int? _knownPositiveUnits(int? value) =>
      value != null && value > 0 ? value : null;

  int _compareDemand(SoldMedicineDemand a, SoldMedicineDemand b) {
    final units = b.unitsSold.compareTo(a.unitsSold);
    if (units != 0) return units;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  bool _hasRecordedFinalSale(Medicine medicine, Set<String> saleWitnesses) {
    final soldAt = medicine.soldAt == null
        ? null
        : DateTime.tryParse(medicine.soldAt!);
    if (soldAt == null) return false;
    return saleWitnesses.contains(_finalSaleWitness(medicine.id, soldAt));
  }

  void _record({
    required String name,
    required int units,
    required int? knownValuePaise,
  }) {
    recordedSales++;
    totalUnitsSold += units;
    if (knownValuePaise == null) {
      unknownValueSales++;
    } else {
      salesValuePaise = checkedMoneySum(salesValuePaise, knownValuePaise);
    }

    final key = normalize(name);
    if (key.isEmpty) return;
    final demand = _byMedicine.putIfAbsent(
      key,
      () => SoldMedicineDemand(key: key, name: name.trim()),
    );
    demand.unitsSold += units;
    demand.recordedSales++;
    if (knownValuePaise == null) {
      demand.unknownValueSales++;
    } else {
      demand.knownSalesValuePaise = checkedMoneySum(
        demand.knownSalesValuePaise,
        knownValuePaise,
      );
    }
  }

  SoldMedicineDemand? get topDemand {
    if (_topDemandResolved) return _topDemandCache;

    SoldMedicineDemand? top;
    for (final item in _byMedicine.values) {
      if (item.unitsSold <= 0) continue;
      if (top == null || _compareDemand(item, top) < 0) {
        top = item;
      }
    }
    _topDemandCache = top;
    _topDemandResolved = true;
    return top;
  }

  List<SoldMedicineDemand> get ranked {
    final cached = _rankedCache;
    if (cached != null) return cached;
    final result = _byMedicine.values
        .where((item) => item.unitsSold > 0)
        .toList();
    result.sort(_compareDemand);
    return _rankedCache = List<SoldMedicineDemand>.unmodifiable(result);
  }
}
