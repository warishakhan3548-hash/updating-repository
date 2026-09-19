import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/inventory.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/supplier.dart';
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

  test('search dataset epoch changes only when medicine rows change', () async {
    final medicine = Medicine(
      id: 'search-cache-stock',
      name: 'Search Cache Medicine',
      strength: '500mg',
      form: 'Tablet',
      quantity: 10,
      expiry: DateTime(2027, 1, 1),
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          records: <String, Medicine>{medicine.id: medicine},
        ),
      ),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    final initialEpoch = controller.debugSearchDatasetEpoch;

    await controller.setShortWarningDays(5);
    expect(
      controller.debugSearchDatasetEpoch,
      initialEpoch,
      reason:
          'Warning preferences change scope semantics, not the searchable medicine dataset.',
    );

    final live = controller.snapshot.records[medicine.id]!;
    await controller.save(
      live.patch(<String, dynamic>{'quantity': 9}),
      expectedRevision: controller.snapshot.revision,
    );
    expect(controller.debugSearchDatasetEpoch, initialEpoch + 1);
  });

  test('fallback fuzzy index survives metadata-only snapshot writes', () async {
    final medicine = Medicine(
      id: 'fallback-search-cache-stock',
      name: 'Drotaverine',
      strength: '80mg',
      form: 'Tablet',
      quantity: 10,
      expiry: DateTime(2027, 1, 1),
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          records: <String, Medicine>{medicine.id: medicine},
        ),
      ),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    expect(controller.debugWebSearchIndexBuilds, 0);
    final first = await controller.search('Drotaverine', SearchScope.all);
    expect(first.single.id, medicine.id);
    expect(controller.debugWebSearchIndexBuilds, 1);

    final datasetEpoch = controller.debugSearchDatasetEpoch;
    await controller.setShortWarningDays(5);
    expect(controller.debugSearchDatasetEpoch, datasetEpoch);

    final second = await controller.search('Drotaverine', SearchScope.all);
    expect(second.single.id, medicine.id);
    expect(
      controller.debugWebSearchIndexBuilds,
      1,
      reason:
          'Warning preferences change scope semantics but not the fuzzy medicine dataset.',
    );
  });

  test('metadata writes invalidate only dependent read models', () async {
    final medicine = Medicine(
      id: 'dependency-cache-stock',
      name: 'Dependency Cache Medicine',
      strength: '500mg',
      form: 'Tablet',
      quantity: 10,
      expiry: DateTime(2027, 1, 1),
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          records: <String, Medicine>{medicine.id: medicine},
        ),
      ),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    final range = TrackingRange.lastDays(controller.today, 30);
    final statsBefore = controller.stats;
    final homeBefore = controller.homeProjection;
    final trackingBefore = controller.tracking(range);
    final returnsBefore = controller.supplierReturns;
    final warningPreview = controller.homeProjectionFor(
      WarningSettings(shortDays: 5, months: controller.settings.months),
    );

    await controller.setShortWarningDays(5);

    expect(identical(statsBefore, controller.stats), isTrue);
    expect(identical(homeBefore, controller.homeProjection), isFalse);
    expect(
      identical(warningPreview, controller.homeProjection),
      isTrue,
      reason:
          'The optimistic Home projection should become authoritative without another stock scan.',
    );
    expect(identical(trackingBefore, controller.tracking(range)), isTrue);
    expect(identical(returnsBefore, controller.supplierReturns), isTrue);

    final statsAfterWarning = controller.stats;
    final homeAfterWarning = controller.homeProjection;
    final trackingAfterWarning = controller.tracking(range);
    final returnsAfterWarning = controller.supplierReturns;

    await controller.saveSupplier(
      const Supplier(
        id: 'dependency-cache-supplier',
        name: 'Dependency Cache Supplier',
        returnBeforeExpiryDays: 30,
      ),
      expectedRevision: controller.snapshot.revision,
    );

    expect(identical(statsAfterWarning, controller.stats), isTrue);
    expect(identical(homeAfterWarning, controller.homeProjection), isTrue);
    expect(identical(trackingAfterWarning, controller.tracking(range)), isTrue);
    expect(identical(returnsAfterWarning, controller.supplierReturns), isFalse);
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
