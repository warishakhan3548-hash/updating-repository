import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unchanged manual refresh keeps the work queue notifier quiet', () async {
    var now = DateTime(2026, 9, 10, 10);
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => now,
      backgroundSearch: false,
    );
    await controller.initialize();
    final supervisor = AarisAutopilotSupervisor(
      controller,
      debounce: Duration.zero,
    );
    addTearDown(() {
      supervisor.dispose();
      controller.dispose();
    });

    for (var attempt = 0; attempt < 50; attempt++) {
      if (supervisor.workQueue.value.isReady) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final firstQueue = supervisor.workQueue.value;
    var queueNotifications = 0;
    void countQueueNotification() => queueNotifications++;
    supervisor.workQueue.addListener(countQueueNotification);
    addTearDown(
      () => supervisor.workQueue.removeListener(countQueueNotification),
    );

    now = DateTime(2026, 9, 10, 11);
    supervisor.refreshNow();
    for (var attempt = 0; attempt < 50; attempt++) {
      if (supervisor.digest.evaluatedAt == now) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(supervisor.digest.evaluatedAt, now);
    expect(identical(supervisor.workQueue.value, firstQueue), isTrue);
    expect(queueNotifications, 0);
  });
}
