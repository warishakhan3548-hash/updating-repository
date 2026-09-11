import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_intake.dart';
import '../lib/domain/medicine_understanding.dart';

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

  test('video carry preserves unassigned transition frames for next window', () {
    final frames = <MedicineFrameEvidence>[
      for (var sequence = 0; sequence < 20; sequence++)
        MedicineFrameEvidence(
          text: 'frame $sequence',
          sequence: sequence,
          timestampMs: sequence * 800,
        ),
    ];
    final draft = MedicineScanDraft(
      fields: const <String, ExtractedMedicineField>{},
      rawText: 'current medicine',
      searchKeywords: '',
      frameSequences: const <int>[2, 3, 4],
    );

    final result = finishMedicineVideoWindow(
      frames,
      <MedicineScanDraft>[draft],
      isLast: false,
    );

    expect(result.completed, isEmpty);
    expect(
      result.carry.map((frame) => frame.sequence),
      orderedEquals(<int>[2, 3, 4, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]),
    );
  });

  test('video carry emits completed drafts once and stays bounded', () {
    final frames = <MedicineFrameEvidence>[
      for (var sequence = 0; sequence < 80; sequence++)
        MedicineFrameEvidence(text: 'frame $sequence', sequence: sequence),
    ];
    const first = MedicineScanDraft(
      fields: <String, ExtractedMedicineField>{},
      rawText: 'finished',
      searchKeywords: '',
      frameSequences: <int>[0, 1, 2],
    );
    final unresolved = MedicineScanDraft(
      fields: const <String, ExtractedMedicineField>{},
      rawText: 'unresolved',
      searchKeywords: '',
      frameSequences: <int>[for (var sequence = 3; sequence < 80; sequence++) sequence],
    );

    final result = finishMedicineVideoWindow(
      frames,
      <MedicineScanDraft>[first, unresolved],
      isLast: false,
    );

    expect(result.completed, hasLength(1));
    expect(result.completed.single.rawText, 'finished');
    expect(result.carry, hasLength(48));
    expect(result.carry.first.sequence, 3);
    expect(result.carry[23].sequence, 26);
    expect(result.carry[24].sequence, 56);
    expect(result.carry.last.sequence, 79);
  });
}
