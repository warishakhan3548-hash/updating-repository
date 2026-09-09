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

String remainingTimeLabel(int days) {
  if (days == 0) return 'Expires today';
  if (days < 30) return '$days ${days == 1 ? 'day' : 'days'} left';
  final months = days ~/ 30;
  final remainder = days % 30;
  return [
    '$months ${months == 1 ? 'month' : 'months'}',
    if (remainder > 0) '$remainder ${remainder == 1 ? 'day' : 'days'}',
    'left',
  ].join(' ');
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
  final label = remainingTimeLabel(days);
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
      label,
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
  var order = 0;
  if (ad == null && bd != null) return 1;
  if (bd == null && ad != null) return -1;
  if (ad != null && bd != null) {
    order = ad < 0 && bd < 0 ? bd.compareTo(ad) : ad.compareTo(bd);
  }
  if (order != 0) return order;
  order = normalize(a.title).compareTo(normalize(b.title));
  if (order != 0) return order;
  order = normalize(a.address).compareTo(normalize(b.address));
  return order != 0 ? order : a.id.compareTo(b.id);
}

/// Whether this physical stock entry is past its last valid dispensing day.
///
/// Missing expiry remains an explicitly unknown fact rather than being treated
/// as expired. The UI must surface that uncertainty to the pharmacist.
bool isExpiredOn(Medicine record, DateTime date) {
  final days = record.daysLeft(civilDay(date));
  return days != null && days < 0;
}

/// Stock that may participate in a dispensing decision on [date].
///
/// Quantity is deliberately not part of this predicate: an unknown quantity is
/// still a real stock entry. A recorded manufacturing date in the future is not
/// dispensable and must be verified rather than treated as usable stock. Callers
/// that need an available batch must separately exclude a known zero quantity.
bool isDispensableOn(Medicine record, DateTime date) {
  final day = civilDay(date);
  return !record.archived &&
      !record.sold &&
      !isExpiredOn(record, day) &&
      (record.mfg == null || !day.isBefore(civilDay(record.mfg!)));
}

/// Rejects a stock movement on a date that contradicts immutable pack facts.
/// Expiry is inclusive: dispensing on the recorded expiry day is valid.
void validateDispensingDate(Medicine record, DateTime occurredAt) {
  final day = civilDay(occurredAt);
  if (record.mfg != null && day.isBefore(record.mfg!)) {
    throw const FormatException(
      'Sale date cannot be before this stock manufacturing date.',
    );
  }
  if (isExpiredOn(record, day)) {
    throw const FormatException(
      'Expired stock cannot be sold. Choose a sale date on or before expiry only for a genuine historical entry.',
    );
  }
}

/// First-expiry-first-out (FEFO) choices for the same medicine identity.
///
/// Known, valid expiries are preferred over unknown expiries. A known zero
/// quantity is unavailable, while an unknown quantity remains eligible but is
/// sorted behind a known positive quantity when the expiry is identical.
List<Medicine> dispensingCandidates(
  Iterable<Medicine> records,
  Medicine requested,
  DateTime date,
) {
  final result = records
      .where(
        (record) =>
            record.identity == requested.identity &&
            isDispensableOn(record, date) &&
            record.quantity != 0,
      )
      .toList();
  result.sort(_fefoOrder);
  return List<Medicine>.unmodifiable(result);
}

int _fefoOrder(Medicine a, Medicine b) {
  final aExpiry = a.expiry;
  final bExpiry = b.expiry;
  if (aExpiry == null && bExpiry != null) return 1;
  if (bExpiry == null && aExpiry != null) return -1;
  if (aExpiry != null && bExpiry != null) {
    final expiry = aExpiry.compareTo(bExpiry);
    if (expiry != 0) return expiry;
  }
  if (a.quantity == null && b.quantity != null) return 1;
  if (b.quantity == null && a.quantity != null) return -1;
  var order = normalize(a.batchNumber).compareTo(normalize(b.batchNumber));
  if (order != 0) return order;
  order = normalize(a.address).compareTo(normalize(b.address));
  return order != 0 ? order : a.id.compareTo(b.id);
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
    final identities = <String>{},
        medicineNames = <String>{},
        salts = <String>{};
    for (final m in records.where((m) => !m.archived)) {
      stockEntries++;
      identities.add(m.identity);
      final normalizedName = normalize(m.name);
      if (normalizedName.isNotEmpty) medicineNames.add(normalizedName);
      if (m.salt.isNotEmpty) salts.add(normalize(m.salt));
      if (m.salt.isEmpty) missingSalt++;

      // `Amount` in the medicine editor is a money value belonging to that
      // medicine entry. Snapshot total intentionally sums the entered amounts
      // themselves; it does not multiply them by stock quantity.
      if (m.unitPricePaise != null) {
        totalEnteredAmountPaise = checkedMoneySum(
          totalEnteredAmountPaise,
          m.unitPricePaise!,
        );
      }

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
    uniqueMedicines = identities.length;
    uniqueMedicineNames = medicineNames.length;
    uniqueSalts = salts.length;
  }
  int stockEntries = 0,
      uniqueMedicines = 0,
      uniqueMedicineNames = 0,
      uniqueSalts = 0,
      knownUnits = 0;
  int unknownQuantity = 0,
      unvaluedEntries = 0,
      valuedEntries = 0,
      missingSalt = 0;
  int onHandValue = 0,
      expiredValue = 0,
      totalEnteredAmountPaise = 0,
      soldEntries = 0;
  final Map<String, FormCount> byForm = {};
}
