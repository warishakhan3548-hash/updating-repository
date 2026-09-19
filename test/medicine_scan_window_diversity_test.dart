import 'package:aaris_pharmacy/domain/medicine_scan_guidance.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/offline_evidence_graph.dart';
import 'package:flutter_test/flutter_test.dart';

MedicineFrameEvidence _frame(
  int sequence,
  String text, {
  String barcode = '',
  double quality = .90,
}) => MedicineFrameEvidence(
  sequence: sequence,
  text: text,
  barcode: barcode,
  quality: quality,
);

void main() {
  group('single-pack evidence window diversity', () {
    test('repeated back views collapse without evicting complementary front identity', () {
      var window = mergeSinglePackMedicineEvidence(
        const <MedicineFrameEvidence>[],
        _frame(0, 'DOLO 650 PARACETAMOL TABLETS FRONT'),
        maxFrames: 6,
      );

      for (var sequence = 1; sequence <= 12; sequence++) {
        window = mergeSinglePackMedicineEvidence(
          window.frames,
          _frame(
            sequence,
            'BATCH LOT7 EXP 10/2027 STORAGE BACK PANEL',
            quality: .94,
          ),
          maxFrames: 6,
        );
      }

      // Exact duplicate observations must not manufacture evidence authority or
      // consume the finite window. Keep the complementary front observation and
      // only the newest/best copy of the repeated back panel.
      expect(window.frames, hasLength(2));
      expect(
        window.frames.where((frame) => frame.text.contains('FRONT')),
        hasLength(1),
      );
      expect(
        window.frames.where((frame) => frame.text.contains('EXP 10/2027')),
        hasLength(1),
      );
      expect(window.frames.last.sequence, 12);
    });

    test('better duplicate moves to newest chronological position', () {
      var window = mergeSinglePackMedicineEvidence(
        const <MedicineFrameEvidence>[],
        _frame(1, 'DOLO 650 FRONT', quality: .50),
        maxFrames: 6,
      );
      window = mergeSinglePackMedicineEvidence(
        window.frames,
        _frame(2, 'COMPOSITION PARACETAMOL 650 MG', quality: .85),
        maxFrames: 6,
      );
      window = mergeSinglePackMedicineEvidence(
        window.frames,
        _frame(10, 'DOLO 650 FRONT', quality: .95),
        maxFrames: 6,
      );

      expect(
        window.frames.where((frame) => frame.text == 'DOLO 650 FRONT'),
        hasLength(1),
      );
      expect(window.frames.last.sequence, 10);
    });

    test('different trusted GTIN still resets the one-pack session', () {
      final first = _frame(
        1,
        'FIRST MEDICINE',
        barcode: '09504000059118',
      );
      final second = _frame(
        2,
        'SECOND MEDICINE',
        barcode: '09501101530003',
      );
      final window = mergeSinglePackMedicineEvidence([first], second);

      expect(window.startedNewPack, isTrue);
      expect(window.frames, hasLength(1));
      expect(window.frames.single.sequence, 2);
    });

    test('same GTIN conflicting expiry stays visible for fail-closed review', () {
      final first = _frame(
        1,
        'DOLO 650 PARACETAMOL TABLETS',
        barcode: '(01)09504000059118(17)271031(10)LOT7',
      );
      final second = _frame(
        2,
        'DOLO 650 PARACETAMOL TABLETS',
        barcode: '(01)09504000059118(17)281031(10)LOT7',
      );
      final window = mergeSinglePackMedicineEvidence([first], second);

      expect(window.startedNewPack, isFalse);
      expect(window.frames, hasLength(2));
      expect(
        buildOfflineEvidenceGraph(window.frames).independentObservations,
        2,
      );
    });
  });
}
