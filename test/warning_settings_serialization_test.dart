import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PharmacyController controller() => PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 20, 10),
    backgroundSearch: false,
  );

  test('rapid warning selectors preserve both field intents', () async {
    final c = controller();
    await c.initialize();
    addTearDown(c.dispose);

    // Queue both taps before the first serialized storage write gets a chance
    // to publish its new revision. Each intent must derive from the live
    // settings when its own write turn starts.
    final short = c.setShortWarningDays(5);
    final months = c.setWarningMonths(3);
    await Future.wait<void>(<Future<void>>[short, months]);

    expect(c.settings.shortDays, 5);
    expect(c.settings.months, 3);
    expect(c.snapshot.revision, 2);
  });

  test('warning preference rebases behind an independent queued write', () async {
    final c = controller();
    await c.initialize();
    addTearDown(c.dispose);

    final save = c.save(
      Medicine.fromJson(<String, dynamic>{
        'id': 'queued-stock',
        'name': 'Dolo',
        'quantity': 10,
      }),
      expectedRevision: c.snapshot.revision,
    );
    final warning = c.setShortWarningDays(5);

    await Future.wait<void>(<Future<void>>[save, warning]);

    expect(c.snapshot.records['queued-stock']?.quantity, 10);
    expect(c.settings.shortDays, 5);
    expect(c.settings.months, 2);
    expect(c.snapshot.revision, 2);
  });

  test('full warning dialog update still applies atomically on its turn', () async {
    final c = controller();
    await c.initialize();
    addTearDown(c.dispose);

    final save = c.save(
      Medicine.fromJson(<String, dynamic>{
        'id': 'other-stock',
        'name': 'Cefixime',
        'quantity': 4,
      }),
      expectedRevision: c.snapshot.revision,
    );
    final warning = c.setWarnings(
      const WarningSettings(shortDays: 10, months: 3),
    );

    await Future.wait<void>(<Future<void>>[save, warning]);

    expect(c.settings.shortDays, 10);
    expect(c.settings.months, 3);
    expect(c.snapshot.revision, 2);
  });
}
