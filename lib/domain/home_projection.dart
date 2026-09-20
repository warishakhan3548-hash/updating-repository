import 'inventory.dart';
import 'medicine.dart';

/// Whether a medicine row still means exactly the same thing to Home.
///
/// Quantity, price, batch, supplier, barcode, notes, OCR, manufacturing,
/// location, brand, manufacturer and salt facts are intentionally absent:
/// Home no longer renders or ranks by them. Operational detail belongs to the
/// canonical Today Work queue instead of this lightweight dashboard projection.
/// Keeping this dependency contract explicit lets frequent stock-counter writes
/// stay off the dashboard's O(N) projection/rebuild path without hiding any
/// field that the dashboard actually presents.
bool _sameCivilDate(DateTime? before, DateTime? after) {
  if (before == null || after == null) return before == null && after == null;
  return before.year == after.year &&
      before.month == after.month &&
      before.day == after.day;
}

bool sameHomeProjectionInput(Medicine before, Medicine after) =>
    before.id == after.id &&
    before.name == after.name &&
    before.strength == after.strength &&
    before.form == after.form &&
    _sameCivilDate(before.expiry, after.expiry) &&
    before.expiryMonthOnly == after.expiryMonthOnly &&
    before.sold == after.sold &&
    before.archived == after.archived;

/// Read-only, presentation-sized snapshot for the Home dashboard.
///
/// Home previously asked the controller for five independently filtered/sorted
/// lists and then rebuilt InventoryStats just to show one unique-medicine count.
/// On a large pharmacy that repeated full-inventory work on every controller
/// notification. This projection walks authoritative stock once and keeps only
/// counts/identity facts Home actually renders. Operational rows are owned by
/// Aaris Autopilot's canonical Today Work queue.
class HomeInventoryProjection {
  HomeInventoryProjection._({
    required this.activeCount,
    required this.uniqueMedicines,
    required this.shortExpiryCount,
    required this.monthExpiryCount,
    required this.expiredCount,
    required this.soldCount,
  });

  factory HomeInventoryProjection.build({
    required Iterable<Medicine> medicines,
    required WarningSettings settings,
    required DateTime today,
  }) {
    final day = civilDay(today);
    final identities = <String>{};
    var activeCount = 0;
    var shortCount = 0;
    var monthCount = 0;
    var expiredCount = 0;
    var soldCount = 0;


    for (final medicine in medicines) {
      if (medicine.archived) continue;
      activeCount++;
      identities.add(medicine.identity);
      switch (statusOf(medicine, settings, day).status) {
        case StockStatus.shortExpiry:
          shortCount++;
        case StockStatus.monthExpiry:
          monthCount++;
        case StockStatus.expired:
          expiredCount++;
        case StockStatus.sold:
          soldCount++;
        case StockStatus.normal:
        case StockStatus.archived:
          break;
      }
    }

    return HomeInventoryProjection._(
      activeCount: activeCount,
      uniqueMedicines: identities.length,
      shortExpiryCount: shortCount,
      monthExpiryCount: monthCount,
      expiredCount: expiredCount,
      soldCount: soldCount,
    );
  }

  final int activeCount;
  final int uniqueMedicines;
  final int shortExpiryCount;
  final int monthExpiryCount;
  final int expiredCount;
  final int soldCount;

  bool get isEmpty => activeCount == 0;
}
