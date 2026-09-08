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

    for (final sale in saleList) {
      final knownValue = sale.totalAmountPaise ??
          (sale.savedUnitPricePaise == null
              ? null
              : stockValue(sale.quantity, sale.savedUnitPricePaise!));
      _record(
        name: sale.medicineName,
        units: sale.quantity,
        knownValuePaise: knownValue,
      );
    }

    // A direct "Mark stock SOLD" action historically changed the stock state
    // without creating a SaleEvent. Persistence still records that transition
    // in the inventory event log. Fold those transitions into the same sales
    // analytics so SOLD immediately updates Sales Value and the demand tracker.
    final directSoldStockIds = <String>{};
    for (final event in events) {
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
          ? _positiveUnits(current!.soldQuantity)
          : _positiveUnits(before.quantity);
      final name = useCurrentSoldSnapshot ? current!.name : before.name;

      int? amount = useCurrentSoldSnapshot
          ? current!.soldUnitPricePaise ?? current!.unitPricePaise
          : before.unitPricePaise;

      // The legacy event aggregate stored quantity × amount. Recover the
      // original entered medicine amount when the old quantity is known.
      if (!useCurrentSoldSnapshot &&
          soldValue is int &&
          soldValue > 0 &&
          before.quantity != null &&
          before.quantity! > 0 &&
          soldValue % before.quantity! == 0) {
        amount = soldValue ~/ before.quantity!;
      }

      _record(name: name, units: units, knownValuePaise: amount);
    }

    // Backups or very old databases can contain a currently SOLD medicine even
    // when its transition event is unavailable. Count it once as a safe
    // fallback, unless a real final-sale event already represents that SOLD.
    for (final medicine in medicineList.where((medicine) => medicine.sold)) {
      if (directSoldStockIds.contains(medicine.id)) continue;
      if (_hasRecordedFinalSale(medicine, saleList)) continue;
      _record(
        name: medicine.name,
        units: _positiveUnits(medicine.soldQuantity),
        knownValuePaise:
            medicine.soldUnitPricePaise ?? medicine.unitPricePaise,
      );
    }
  }

  int recordedSales = 0;
  int totalUnitsSold = 0;
  int salesValuePaise = 0;
  int unknownValueSales = 0;
  final Map<String, SoldMedicineDemand> _byMedicine = {};

  int _positiveUnits(int? value) => value != null && value > 0 ? value : 1;

  bool _hasRecordedFinalSale(Medicine medicine, List<SaleEvent> sales) {
    final soldAt = medicine.soldAt == null
        ? null
        : DateTime.tryParse(medicine.soldAt!);
    if (soldAt == null) return false;
    return sales.any(
      (sale) =>
          sale.stockId == medicine.id &&
          sale.occurredAt.toUtc().microsecondsSinceEpoch ==
              soldAt.toUtc().microsecondsSinceEpoch,
    );
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

  List<SoldMedicineDemand> get ranked {
    final result = _byMedicine.values.where((item) => item.unitsSold > 0).toList();
    result.sort((a, b) {
      final units = b.unitsSold.compareTo(a.unitsSold);
      if (units != 0) return units;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }
}
