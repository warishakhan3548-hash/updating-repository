import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/offline_evidence_graph.dart';
import 'package:aaris_pharmacy/domain/spatial_traceability.dart';
import 'package:flutter_test/flutter_test.dart';

MedicineFrameEvidence _frame({
  required int sequence,
  String text = 'DOLO 650 PARACETAMOL TABLETS',
  String barcode = '',
  double quality = .92,
  List<MedicineTextLineEvidence> layoutLines =
      const <MedicineTextLineEvidence>[],
}) => MedicineFrameEvidence(
  text: text,
  barcode: barcode,
  sequence: sequence,
  quality: quality,
  layoutLines: layoutLines,
);

void main() {
  group('bounded offline evidence selection', () {
    test('late complementary pack side survives early duplicate saturation', () {
      final frames = <MedicineFrameEvidence>[
        for (var i = 0; i < 20; i++) _frame(sequence: i),
        _frame(
          sequence: 20,
          quality: .38,
          text: 'COMPOSITION PARACETAMOL 650 MG BATCH LOT7 EXP 10/2027',
        ),
      ];

      final selected = selectOfflineEvidenceFrames(frames, maxFrames: 6);
      expect(selected, hasLength(6));
      expect(selected.any((frame) => frame.sequence == 20), isTrue);

      final graph = buildOfflineEvidenceGraph(frames, maxFrames: 6);
      expect(
        graph.groups.any(
          (group) => group.representative.text.contains('BATCH LOT7'),
        ),
        isTrue,
      );
    });

    test('late conflicting trusted GTIN cannot be starved by duplicate frames', () {
      final frames = <MedicineFrameEvidence>[
        for (var i = 0; i < 18; i++)
          _frame(sequence: i, barcode: '09504000059118'),
        _frame(
          sequence: 18,
          barcode: '09501101530003',
          text: 'OTHER MEDICINE TABLETS',
          quality: .42,
        ),
        _frame(sequence: 19, barcode: '09504000059118'),
      ];

      final selected = selectOfflineEvidenceFrames(frames, maxFrames: 4);
      expect(
        selected.any((frame) => frame.barcode == '09501101530003'),
        isTrue,
      );
      final graph = buildOfflineEvidenceGraph(frames, maxFrames: 4);
      expect(graph.independentObservations, greaterThanOrEqualTo(2));
    });

    test('same GTIN with conflicting encoded expiry remains independent', () {
      final graph = buildOfflineEvidenceGraph([
        _frame(
          sequence: 1,
          barcode: '(01)09504000059118(17)271031(10)LOT7',
        ),
        _frame(
          sequence: 2,
          barcode: '(01)09504000059118(17)281031(10)LOT7',
        ),
      ]);
      expect(graph.independentObservations, 2);
    });

    test('late requested date view reaches temporal reasoning', () {
      final frames = <MedicineFrameEvidence>[
        for (var i = 0; i < 20; i++) _frame(sequence: i),
        _frame(
          sequence: 20,
          quality: .40,
          text: 'MFG 05/2026\nEXP 10/2027\nBATCH LOT7',
        ),
      ];

      final result = inferMedicineDateIntelligence(
        frames: frames,
        referenceDate: DateTime.utc(2026, 9, 13),
      );
      expect(result.manufacturing?.date.value, '2026-05');
      expect(result.expiry?.date.value, '2027-10');
      expect(result.conflicted, isFalse);
    });

    test('spatial binder consumes every already-bounded diverse graph group', () {
      const independentPanels = <String>[
        'ASPIRIN RED BOX',
        'CEFIXIME BLUE STRIP',
        'METFORMIN SILVER PACK',
        'AMLODIPINE GREEN CARTON',
        'IBUPROFEN WHITE BLISTER',
        'AZITHROMYCIN ORANGE LABEL',
        'CETIRIZINE PURPLE FOIL',
        'OMEPRAZOLE YELLOW CASE',
        'LOSARTAN BROWN SLEEVE',
        'ATORVASTATIN BLACK PANEL',
        'LEVOCETIRIZINE PINK SIDE',
      ];
      final frames = <MedicineFrameEvidence>[
        for (var i = 0; i < independentPanels.length; i++)
          _frame(
            sequence: i,
            quality: .96,
            text: independentPanels[i],
          ),
        _frame(
          sequence: 11,
          quality: .30,
          text: 'EXP\n10/2027',
          layoutLines: const <MedicineTextLineEvidence>[
            MedicineTextLineEvidence(
              text: 'EXP',
              left: 10,
              top: 10,
              width: 40,
              height: 20,
            ),
            MedicineTextLineEvidence(
              text: '10/2027',
              left: 60,
              top: 10,
              width: 80,
              height: 20,
            ),
          ],
        ),
      ];

      final graph = buildOfflineEvidenceGraph(frames, maxFrames: 12);
      expect(graph.independentObservations, greaterThan(8));
      final result = inferSpatialTraceability(frames);
      expect(result.expiry?.value, '2027-10');
      expect(result.expiry?.conflicted, isFalse);
    });

    test('selection is stable and keeps chronological output order', () {
      final frames = <MedicineFrameEvidence>[
        for (var i = 0; i < 30; i++)
          _frame(
            sequence: i,
            text: i % 7 == 0
                ? 'COMPOSITION PARACETAMOL 650 MG PANEL $i'
                : 'DOLO 650 PARACETAMOL TABLETS',
            quality: .55 + (i % 5) * .08,
          ),
      ];

      final first = selectOfflineEvidenceFrames(frames, maxFrames: 8)
          .map((frame) => frame.sequence)
          .toList();
      final second = selectOfflineEvidenceFrames(frames, maxFrames: 8)
          .map((frame) => frame.sequence)
          .toList();
      expect(second, first);
      expect(first, orderedEquals([...first]..sort()));
      expect(first.last, 29);
    });
  });
}
