import 'inventory.dart';
import 'medicine.dart';
import 'tracking.dart';

/// Operational priority for pharmacist-facing work.
///
/// This is deliberately deterministic. It never guesses clinical facts and it
/// never mutates stock. The queue only orders already-known inventory facts so a
/// pharmacist can deal with safety, availability and data-quality work quickly.
enum PharmacistTaskPriority { critical, high, routine }

enum PharmacistTaskKind {
  expired,
  shortExpiry,
  monthExpiry,
  soldOut,
  zeroQuantity,
  reorder,
  missingExpiry,
  missingQuantity,
  missingLocation,
}

class PharmacistTask {
  const PharmacistTask({
    required this.id,
    required this.kind,
    required this.priority,
    required this.title,
    required this.message,
    required this.productKey,
    required this.sortHint,
    this.recordId,
    this.daysLeft,
    this.suggestedQuantity,
  });

  final String id;
  final PharmacistTaskKind kind;
  final PharmacistTaskPriority priority;
  final String title;
  final String message;
  final String productKey;
  final String? recordId;
  final int? daysLeft;
  final int? suggestedQuantity;

  /// Stable secondary order inside the same priority bucket.
  final int sortHint;
}

class PharmacyWorkQueue {
  PharmacyWorkQueue._(List<PharmacistTask> tasks)
    : tasks = List<PharmacistTask>.unmodifiable(tasks),
      criticalCount = tasks
          .where((task) => task.priority == PharmacistTaskPriority.critical)
          .length,
      highCount = tasks
          .where((task) => task.priority == PharmacistTaskPriority.high)
          .length,
      routineCount = tasks
          .where((task) => task.priority == PharmacistTaskPriority.routine)
          .length;

  factory PharmacyWorkQueue.build({
    required Iterable<Medicine> medicines,
    required Iterable<SaleEvent> sales,
    required WarningSettings settings,
    required DateTime today,
    int reorderWindowDays = 30,
  }) {
    if (reorderWindowDays < 1 || reorderWindowDays > 3660) {
      throw const FormatException(
        'Work-queue reorder window must be between 1 and 3660 days.',
      );
    }

    final day = civilDay(today);
    final active = medicines
        .where((medicine) => !medicine.archived)
        .toList(growable: false);
    final tasks = <PharmacistTask>[];
    final strongestByProduct = <String, PharmacistTaskPriority>{};

    void addRecordTask(PharmacistTask task) {
      tasks.add(task);
      final current = strongestByProduct[task.productKey];
      if (current == null || task.priority.index < current.index) {
        strongestByProduct[task.productKey] = task.priority;
      }
    }

    for (final medicine in active) {
      final status = statusOf(medicine, settings, day);
      final days = status.days;
      PharmacistTask? task;

      if (status.status == StockStatus.expired) {
        final overdue = days == null ? 0 : -days;
        task = PharmacistTask(
          id: 'expired:${medicine.id}',
          kind: PharmacistTaskKind.expired,
          priority: PharmacistTaskPriority.critical,
          title: medicine.title,
          message: overdue == 1
              ? 'Expired 1 day ago · segregate or remove this stock before dispensing.'
              : 'Expired $overdue days ago · segregate or remove this stock before dispensing.',
          productKey: medicine.identity,
          recordId: medicine.id,
          daysLeft: days,
          sortHint: overdue,
        );
      } else if (status.status == StockStatus.sold) {
        task = PharmacistTask(
          id: 'sold:${medicine.id}',
          kind: PharmacistTaskKind.soldOut,
          priority: PharmacistTaskPriority.high,
          title: medicine.title,
          message: 'Out of stock · review reorder or restock this medicine.',
          productKey: medicine.identity,
          recordId: medicine.id,
          daysLeft: days,
          sortHint: 0,
        );
      } else if (status.status == StockStatus.shortExpiry) {
        task = PharmacistTask(
          id: 'short:${medicine.id}',
          kind: PharmacistTaskKind.shortExpiry,
          priority: PharmacistTaskPriority.high,
          title: medicine.title,
          message: days == 0
              ? 'Expires today · review this stock now and use FEFO when dispensing.'
              : '$days ${days == 1 ? 'day' : 'days'} left · review this stock and use FEFO when dispensing.',
          productKey: medicine.identity,
          recordId: medicine.id,
          daysLeft: days,
          sortHint: days ?? 0,
        );
      } else if (medicine.quantity == 0) {
        task = PharmacistTask(
          id: 'zero:${medicine.id}',
          kind: PharmacistTaskKind.zeroQuantity,
          priority: PharmacistTaskPriority.high,
          title: medicine.title,
          message:
              '0 units are recorded but this entry is not marked SOLD · confirm the real stock or restock it.',
          productKey: medicine.identity,
          recordId: medicine.id,
          daysLeft: days,
          sortHint: 50,
        );
      } else if (medicine.expiry == null) {
        task = PharmacistTask(
          id: 'missing-expiry:${medicine.id}',
          kind: PharmacistTaskKind.missingExpiry,
          priority: PharmacistTaskPriority.routine,
          title: medicine.title,
          message:
              'Expiry is not recorded · add it so warnings and dispensing safeguards can work.',
          productKey: medicine.identity,
          recordId: medicine.id,
          sortHint: 10,
        );
      } else if (medicine.quantity == null) {
        task = PharmacistTask(
          id: 'missing-quantity:${medicine.id}',
          kind: PharmacistTaskKind.missingQuantity,
          priority: PharmacistTaskPriority.routine,
          title: medicine.title,
          message:
              'Quantity is unknown · add a count for stock totals and reorder planning.',
          productKey: medicine.identity,
          recordId: medicine.id,
          daysLeft: days,
          sortHint: 20,
        );
      } else if (medicine.address.isEmpty) {
        task = PharmacistTask(
          id: 'missing-location:${medicine.id}',
          kind: PharmacistTaskKind.missingLocation,
          priority: PharmacistTaskPriority.routine,
          title: medicine.title,
          message:
              'Storage location is missing · add Block / Row / Vertical or a free-form location.',
          productKey: medicine.identity,
          recordId: medicine.id,
          daysLeft: days,
          sortHint: 30,
        );
      } else if (status.status == StockStatus.monthExpiry) {
        task = PharmacistTask(
          id: 'month:${medicine.id}',
          kind: PharmacistTaskKind.monthExpiry,
          priority: PharmacistTaskPriority.routine,
          title: medicine.title,
          message:
              '${remainingTimeLabel(days ?? settings.monthDays)} · plan movement before this stock becomes short-expiry.',
          productKey: medicine.identity,
          recordId: medicine.id,
          daysLeft: days,
          sortHint: 100 + (days ?? settings.monthDays),
        );
      }

      if (task != null) addRecordTask(task);
    }

    final tracking = TrackingStats(
      medicines: active,
      sales: sales,
      range: TrackingRange.lastDays(day, reorderWindowDays),
      today: day,
    );

    for (final suggestion in tracking.reorder) {
      final priority = suggestion.priority == ReorderPriority.urgent
          ? PharmacistTaskPriority.high
          : PharmacistTaskPriority.routine;
      final existing = strongestByProduct[suggestion.productKey];

      // Do not repeat the same operational problem. For example, a SOLD or
      // expired batch already has a stronger task; once that task is resolved,
      // reorder advice can naturally surface on the next queue rebuild.
      if (existing != null && existing.index <= priority.index) continue;

      final recordId = suggestion.stockIds
          .where((id) => active.any((medicine) => medicine.id == id))
          .firstOrNull;
      final current = suggestion.currentQuantity == null
          ? 'current quantity unknown'
          : '${suggestion.currentQuantity} units on hand';
      final rate = suggestion.unitsPerDay > 0
          ? ' · ${suggestion.unitsPerDay.toStringAsFixed(1)} units/day'
          : '';
      tasks.add(
        PharmacistTask(
          id: 'reorder:${suggestion.productKey}',
          kind: PharmacistTaskKind.reorder,
          priority: priority,
          title: suggestion.title,
          message:
              '${suggestion.reason} · $current$rate · suggested order ${suggestion.suggestedQuantity}.',
          productKey: suggestion.productKey,
          recordId: recordId,
          suggestedQuantity: suggestion.suggestedQuantity,
          sortHint: suggestion.priority == ReorderPriority.urgent ? 60 : 200,
        ),
      );
    }

    tasks.sort((a, b) {
      var order = a.priority.index.compareTo(b.priority.index);
      if (order != 0) return order;
      order = a.sortHint.compareTo(b.sortHint);
      if (order != 0) return order;
      order = normalize(a.title).compareTo(normalize(b.title));
      return order != 0 ? order : a.id.compareTo(b.id);
    });
    return PharmacyWorkQueue._(tasks);
  }

  final List<PharmacistTask> tasks;
  final int criticalCount;
  final int highCount;
  final int routineCount;

  int get total => tasks.length;
  bool get isClear => tasks.isEmpty;
  int get safetyCount => tasks
      .where(
        (task) =>
            task.kind == PharmacistTaskKind.expired ||
            task.kind == PharmacistTaskKind.shortExpiry,
      )
      .length;
  int get stockCount => tasks
      .where(
        (task) =>
            task.kind == PharmacistTaskKind.soldOut ||
            task.kind == PharmacistTaskKind.zeroQuantity ||
            task.kind == PharmacistTaskKind.reorder,
      )
      .length;
  int get dataQualityCount => tasks
      .where(
        (task) =>
            task.kind == PharmacistTaskKind.missingExpiry ||
            task.kind == PharmacistTaskKind.missingQuantity ||
            task.kind == PharmacistTaskKind.missingLocation,
      )
      .length;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
