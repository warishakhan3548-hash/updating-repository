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

/// Deterministic, all-time sales analytics derived only from recorded sale
/// events. It intentionally does not use AI or infer demand from inventory.
class SalesOverview {
  SalesOverview(Iterable<SaleEvent> sales) {
    for (final sale in sales) {
      recordedSales++;
      totalUnitsSold += sale.quantity;

      final knownValue = sale.totalAmountPaise ??
          (sale.savedUnitPricePaise == null
              ? null
              : stockValue(sale.quantity, sale.savedUnitPricePaise!));
      if (knownValue == null) {
        unknownValueSales++;
      } else {
        salesValuePaise = checkedMoneySum(salesValuePaise, knownValue);
      }

      final key = normalize(sale.medicineName);
      if (key.isEmpty) continue;
      final demand = _byMedicine.putIfAbsent(
        key,
        () => SoldMedicineDemand(key: key, name: sale.medicineName.trim()),
      );
      demand.unitsSold += sale.quantity;
      demand.recordedSales++;
      if (knownValue == null) {
        demand.unknownValueSales++;
      } else {
        demand.knownSalesValuePaise = checkedMoneySum(
          demand.knownSalesValuePaise,
          knownValue,
        );
      }
    }
  }

  int recordedSales = 0;
  int totalUnitsSold = 0;
  int salesValuePaise = 0;
  int unknownValueSales = 0;
  final Map<String, SoldMedicineDemand> _byMedicine = {};

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
