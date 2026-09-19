import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/inventory.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same-day refresh does not publish redundant UI work', () async {
    var now = DateTime(2026, 9, 20, 9);
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => now,
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    var publications = 0;
    controller.addListener(() => publications++);

    controller.refreshDay();
    now = DateTime(2026, 9, 20, 23, 55);
    controller.refreshDay();
    expect(publications, 0);

    now = DateTime(2026, 9, 21, 0, 1);
    controller.refreshDay();
    expect(publications, 1);

    controller.refreshDay();
    expect(publications, 1);
  });

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

    expect(identical(statsDayOne, controller.stats), isTrue);
    expect(identical(homeDayOne, controller.homeProjection), isTrue);
    expect(identical(salesSnapshotOne, controller.salesOverview), isTrue);

    // Expiry/status projections are civil-day dependent, while all-time sales
    // analytics are not. A midnight refresh must therefore invalidate only the
    // day-sensitive read models when the inventory snapshot itself is unchanged.
    now = DateTime(2026, 9, 13, 10);
    controller.refreshDay();

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

  test('settings-only writes preserve record-bound cache witnesses', () async {
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          records: <String, Medicine>{
            'cache-stock': Medicine(
              id: 'cache-stock',
              name: 'Cache Medicine',
              quantity: 10,
              expiry: DateTime(2026, 9, 26),
            ),
          },
        ),
      ),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    final statsBefore = controller.stats;
    final range = TrackingRange.lastDays(controller.today, 30);
    final trackingBefore = controller.tracking(range);

    await controller.setShortWarningDays(5);

    expect(identical(statsBefore, controller.stats), isTrue);
    expect(identical(trackingBefore, controller.tracking(range)), isTrue);
  });

  test('tracking read model is reused by range and invalidated safely', () async {
    var now = DateTime(2026, 9, 12, 10);
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => now,
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    TrackingRange range() => TrackingRange.lastDays(controller.today, 30);

    final dayOne = controller.tracking(range());
    expect(identical(dayOne, controller.tracking(range())), isTrue);

    // Daily-demand and expiry-aware reorder planning are civil-day sensitive.
    now = DateTime(2026, 9, 13, 10);
    controller.refreshDay();
    final dayTwo = controller.tracking(range());
    expect(identical(dayOne, dayTwo), isFalse);
    expect(identical(dayTwo, controller.tracking(range())), isTrue);

    await controller.save(
      Medicine(
        id: 'tracking-cache-stock',
        name: 'Tracking Cache Medicine',
        strength: '500mg',
        form: 'Tablet',
        quantity: 8,
        expiry: DateTime(2027, 1, 1),
      ),
      expectedRevision: controller.snapshot.revision,
    );

    final afterWrite = controller.tracking(range());
    expect(identical(dayTwo, afterWrite), isFalse);
    expect(identical(afterWrite, controller.tracking(range())), isTrue);
  });

}
