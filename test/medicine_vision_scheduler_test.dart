import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/services/scan_service.dart';

void main() {
  test('interactive work runs before queued background work', () async {
    final release = Completer<void>();
    final order = <String>[];

    final active = runMedicineVisionWorkForTesting<void>(
      MedicineVisionWorkPriority.background,
      () async {
        order.add('active');
        await release.future;
      },
    );
    await Future<void>.delayed(Duration.zero);

    final background = runMedicineVisionWorkForTesting<void>(
      MedicineVisionWorkPriority.background,
      () async {
        order.add('background');
      },
    );
    final interactive = runMedicineVisionWorkForTesting<void>(
      MedicineVisionWorkPriority.interactive,
      () async {
        order.add('interactive');
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(order, ['active']);

    release.complete();
    await Future.wait([active, background, interactive]);
    expect(order, ['active', 'interactive', 'background']);
  });

  test('a completed lease allows the next operation to run', () async {
    await runMedicineVisionWorkForTesting<void>(
      MedicineVisionWorkPriority.background,
      () async {},
    );

    var ran = false;
    await runMedicineVisionWorkForTesting<void>(
      MedicineVisionWorkPriority.interactive,
      () async {
        ran = true;
      },
    );
    expect(ran, isTrue);
  });
}
