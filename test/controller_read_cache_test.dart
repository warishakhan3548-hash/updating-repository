import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/inventory.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('derived read models reuse one snapshot and invalidate on the right boundary', () async {
    var now = DateTime(2026, 9, 12, 10);
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => now,
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    final statsDayOne = controller.stats;
    final homeDayOne = controller.homeProjection;
    final salesSnapshotOne = controller.salesOverview;
    var notifications = 0;
    controller.addListener(() => notifications++);

    expect(identical(statsDayOne, controller.stats), isTrue);
    expect(identical(homeDayOne, controller.homeProjection), isTrue);
    expect(identical(salesSnapshotOne, controller.salesOverview), isTrue);

    // Same-day resume/refresh must not repaint every retained tab or invalidate
    // already-correct day-sensitive projections.
    controller.refreshDay();
    expect(notifications, 0);
    expect(identical(statsDayOne, controller.stats), isTrue);
    expect(identical(homeDayOne, controller.homeProjection), isTrue);

    // Expiry/status projections are civil-day dependent, while all-time sales
    // analytics are not. A midnight refresh must therefore invalidate only the
    // day-sensitive read models when the inventory snapshot itself is unchanged.
    now = DateTime(2026, 9, 13, 10);
    controller.refreshDay();

    expect(notifications, 1);
    expect(identical(statsDayOne, controller.stats), isFalse);
    expect(identical(homeDayOne, controller.homeProjection), isFalse);
    expect(identical(salesSnapshotOne, controller.salesOverview), isTrue);

    final statsDayTwo = controller.stats;
    final homeDayTwo = controller.homeProjection;
    final salesBeforeWrite = controller.salesOverview;

    await controller.save(
      Medicine(
        id: 'cache-stock',
        name: 'Cache Test Medicine',
        strength: '500mg',
        form: 'Tablet',
        quantity: 10,
        expiry: DateTime(2027, 1, 1),
      ),
      expectedRevision: controller.snapshot.revision,
    );

    expect(identical(statsDayTwo, controller.stats), isFalse);
    expect(identical(homeDayTwo, controller.homeProjection), isFalse);
    expect(identical(salesBeforeWrite, controller.salesOverview), isFalse);
    expect(controller.homeProjection.activeCount, 1);
  });

  test('scoped list samples the civil day once for the whole projection', () async {
    var clockReads = 0;
    final now = DateTime(2026, 9, 12, 10);
    DateTime clock() {
      clockReads++;
      return now;
    }

    final records = <String, Medicine>{
      for (var i = 0; i < 4; i++)
        'stock-$i': Medicine(
          id: 'stock-$i',
          name: 'Medicine $i',
          strength: '500mg',
          form: 'Tablet',
          quantity: 10,
          expiry: DateTime(2027, 1, i + 1),
        ),
    };
    final controller = PharmacyController(
      MemoryInventoryStorage(InventorySnapshot(records: records)),
      clock: clock,
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    final before = clockReads;
    final result = controller.list(SearchScope.all);

    expect(result, hasLength(4));
    expect(clockReads - before, 1);
  });

  test('direct SOLD save validates and audits one authoritative instant', () async {
    final fallback = DateTime(2026, 9, 19, 12);
    final scripted = <DateTime>[];
    DateTime clock() => scripted.isEmpty ? fallback : scripted.removeAt(0);

    final active = Medicine(
      id: 'midnight-sold',
      name: 'Midnight Test',
      strength: '500mg',
      form: 'Tablet',
      quantity: 1,
      expiry: DateTime(2026, 9, 19),
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(records: <String, Medicine>{active.id: active}),
      ),
      clock: clock,
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    scripted.addAll(<DateTime>[
      DateTime(2026, 9, 19, 23, 59, 59),
      DateTime(2026, 9, 20, 0, 0, 1),
    ]);
    await controller.save(
      active.patch(<String, dynamic>{
        'sold': true,
        'quantity': 0,
        'soldAt': '2026-09-19T23:59:59',
        'soldQuantity': 1,
      }),
      expectedRevision: controller.snapshot.revision,
    );

    expect(controller.snapshot.events.first['businessDay'], '2026-09-19');
    expect(scripted, hasLength(1));
  });
}
