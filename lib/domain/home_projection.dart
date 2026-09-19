import 'inventory.dart';
import 'medicine.dart';

/// Read-only, presentation-sized snapshot for the Home dashboard.
///
/// Home previously asked the controller for five independently filtered/sorted
/// lists and then rebuilt InventoryStats just to show one unique-medicine count.
/// On a large pharmacy that repeated full-inventory work on every controller
/// notification. This projection walks authoritative stock once, keeps only the
/// four rows Home can actually render, and leaves all status rules in [statusOf].
class HomeInventoryProjection {
  HomeInventoryProjection._({
    required this.activeCount,
    required this.uniqueMedicines,
    required this.shortExpiryCount,
    required this.monthExpiryCount,
    required this.expiredCount,
    required this.soldCount,
    required List<Medicine> attention,
  }) : attention = List.unmodifiable(attention);

  factory HomeInventoryProjection.build({
    required Iterable<Medicine> medicines,
    required WarningSettings settings,
    required DateTime today,
  }) {
    final day = civilDay(today);
    final identities = <String>{};
    final expiredTop = <Medicine>[];
    final shortTop = <Medicine>[];
    final monthTop = <Medicine>[];
    var activeCount = 0;
    var shortCount = 0;
    var monthCount = 0;
    var expiredCount = 0;
    var soldCount = 0;

    void retainTopFour(List<Medicine> target, Medicine medicine) {
      target.add(medicine);
      target.sort((a, b) => expiryOrder(a, b, day));
      if (target.length > 4) target.removeLast();
    }

    for (final medicine in medicines) {
      if (medicine.archived) continue;
      activeCount++;
      identities.add(medicine.identity);
      switch (statusOf(medicine, settings, day).status) {
        case StockStatus.shortExpiry:
          shortCount++;
          retainTopFour(shortTop, medicine);
        case StockStatus.monthExpiry:
          monthCount++;
          retainTopFour(monthTop, medicine);
        case StockStatus.expired:
          expiredCount++;
          retainTopFour(expiredTop, medicine);
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
      attention: <Medicine>[
        ...expiredTop,
        ...shortTop,
        ...monthTop,
      ].take(4).toList(growable: false),
    );
  }

  final int activeCount;
  final int uniqueMedicines;
  final int shortExpiryCount;
  final int monthExpiryCount;
  final int expiredCount;
  final int soldCount;
  final List<Medicine> attention;

  bool get isEmpty => activeCount == 0;
}
