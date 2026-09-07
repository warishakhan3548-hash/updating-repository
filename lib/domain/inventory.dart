import 'medicine.dart';

enum StockStatus { normal, shortExpiry, monthExpiry, expired, sold, archived }

enum SearchScope { all, shortExpiry, monthExpiry, expired, sold }

class StatusInfo {
  const StatusInfo(this.status, this.label, this.redFraction, this.days);
  final StockStatus status;
  final String label;
  final double redFraction;
  final int? days;
}

StatusInfo statusOf(Medicine record, WarningSettings settings, DateTime today) {
  final days = record.daysLeft(today);
  if (record.archived)
    return StatusInfo(StockStatus.archived, 'Removed', 0, days);
  if (record.sold)
    return StatusInfo(StockStatus.sold, 'Sold · reorder needed', 0, days);
  if (days == null)
    return const StatusInfo(StockStatus.normal, 'Expiry not provided', 0, null);
  if (days < 0)
    return StatusInfo(
      StockStatus.expired,
      'Expired ${-days} ${days == -1 ? 'day' : 'days'} ago',
      1,
      days,
    );
  final label = days == 0
      ? 'Expires today'
      : '$days ${days == 1 ? 'day' : 'days'} left';
  if (days <= settings.shortDays)
    return StatusInfo(
      StockStatus.shortExpiry,
      label,
      (1 - days / settings.shortDays).clamp(0, 1),
      days,
    );
  if (days <= settings.monthDays) {
    return StatusInfo(
      StockStatus.monthExpiry,
      days < 30
          ? label
          : '${days ~/ 30} ${days < 60 ? 'month' : 'months'} left · $days days',
      (1 - days / settings.monthDays).clamp(0, 1),
      days,
    );
  }
  return StatusInfo(StockStatus.normal, label, 0, days);
}

bool inScope(
  Medicine record,
  SearchScope scope,
  WarningSettings settings,
  DateTime today,
) {
  final status = statusOf(record, settings, today).status;
  if (status == StockStatus.archived) return false;
  return switch (scope) {
    SearchScope.all => true,
    SearchScope.expired => status == StockStatus.expired,
    SearchScope.sold => status == StockStatus.sold,
    SearchScope.shortExpiry => status == StockStatus.shortExpiry,
    SearchScope.monthExpiry => status == StockStatus.monthExpiry,
  };
}

int expiryOrder(Medicine a, Medicine b, DateTime today) {
  final ad = a.daysLeft(today), bd = b.daysLeft(today);
  if (ad == null && bd == null) return a.name.compareTo(b.name);
  if (ad == null) return 1;
  if (bd == null) return -1;
  if (ad < 0 && bd < 0) return bd.compareTo(ad);
  return ad.compareTo(bd);
}

String scopeTitle(SearchScope scope, WarningSettings settings) =>
    switch (scope) {
      SearchScope.all => 'All medicines',
      SearchScope.expired => 'Expired medicines',
      SearchScope.sold => 'Sold medicines',
      SearchScope.shortExpiry => '${settings.shortDays} Days Left',
      SearchScope.monthExpiry =>
        '${settings.months} ${settings.months == 1 ? 'Month' : 'Months'} Left',
    };

class FormCount {
  int records = 0;
  int units = 0;
  int unknownQuantity = 0;
}

class InventoryStats {
  InventoryStats(Iterable<Medicine> records, DateTime today) {
    final names = <String>{}, salts = <String>{};
    for (final m in records.where((m) => !m.archived)) {
      stockEntries++;
      names.add(m.identity);
      if (m.salt.isNotEmpty) salts.add(normalize(m.salt));
      if (m.salt.isEmpty) missingSalt++;
      if (m.sold) {
        soldEntries++;
        continue;
      }
      final form = byForm.putIfAbsent(
        m.form.isEmpty ? 'Unspecified' : m.form,
        FormCount.new,
      );
      form.records++;
      if (m.quantity == null) {
        unknownQuantity++;
        form.unknownQuantity++;
      } else {
        knownUnits += m.quantity!;
        form.units += m.quantity!;
      }
      if (m.quantity == null || m.unitPricePaise == null) {
        unvaluedEntries++;
      } else {
        final value = stockValue(m.quantity!, m.unitPricePaise!);
        onHandValue = checkedMoneySum(onHandValue, value);
        if ((m.daysLeft(today) ?? 1) < 0)
          expiredValue = checkedMoneySum(expiredValue, value);
        valuedEntries++;
      }
    }
    uniqueMedicines = names.length;
    uniqueSalts = salts.length;
  }
  int stockEntries = 0, uniqueMedicines = 0, uniqueSalts = 0, knownUnits = 0;
  int unknownQuantity = 0,
      unvaluedEntries = 0,
      valuedEntries = 0,
      missingSalt = 0;
  int onHandValue = 0, expiredValue = 0, soldEntries = 0;
  final Map<String, FormCount> byForm = {};
}
