import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_intake.dart';

void main() {
  test('terminal action waits for the exact worker-owned capture', () async {
    final barrier = MedicineIntakeWorkBarrier();
    barrier.begin('capture-a');

    var released = false;
    final waiter = barrier.wait('capture-a').then((_) => released = true);
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);

    barrier.finish('capture-a');
    await waiter;
    expect(released, isTrue);
  });

  test(
    'unrelated capture never waits behind the active worker lease',
    () async {
      final barrier = MedicineIntakeWorkBarrier();
      barrier.begin('capture-a');

      await barrier
          .wait('capture-b')
          .timeout(const Duration(milliseconds: 100));
      barrier.finish('capture-a');
    },
  );

  test('stale finalizer cannot release a newer capture lease', () async {
    final barrier = MedicineIntakeWorkBarrier();
    barrier.begin('capture-a');
    barrier.finish('capture-a');
    barrier.begin('capture-b');

    var released = false;
    final waiter = barrier.wait('capture-b').then((_) => released = true);
    barrier.finish('capture-a');
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);

    barrier.finish('capture-b');
    await waiter;
    expect(released, isTrue);
  });
}
