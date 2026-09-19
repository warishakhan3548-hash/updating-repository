import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_understanding.dart';
import '../lib/domain/offline_evidence_graph.dart';

MedicineFrameEvidence _frame({
  String text = '',
  String barcode = '',
  List<String> barcodes = const <String>[],
  int sequence = 0,
  double quality = .75,
}) => MedicineFrameEvidence(
  text: text,
  barcode: barcode,
  barcodes: barcodes,
  sequence: sequence,
  quality: quality,
);

void main() {
  test('barcode-only valid GTIN is first-class graph evidence', () {
    final graph = buildOfflineEvidenceGraph([
      _frame(barcode: '09504000059118'),
    ]);
    expect(graph.observedFrames, 1);
    expect(graph.independentObservations, 1);
    expect(graph.groups.single.representative.barcode, '09504000059118');
  });

  test('repeated barcode-only observation collapses as correlated', () {
    final graph = buildOfflineEvidenceGraph([
      _frame(barcode: '09504000059118', sequence: 1),
      _frame(barcode: '09504000059118', sequence: 2),
    ]);
    expect(graph.observedFrames, 2);
    expect(graph.independentObservations, 1);
    expect(graph.correlatedDuplicates, 1);
  });

  test('different trusted GTINs never merge despite identical text', () {
    final graph = buildOfflineEvidenceGraph([
      _frame(
        text: 'DOLO 650 PARACETAMOL TABLETS',
        barcode: '09504000059118',
        sequence: 1,
      ),
      _frame(
        text: 'DOLO 650 PARACETAMOL TABLETS',
        barcode: '09501101530003',
        sequence: 2,
      ),
    ]);
    expect(graph.independentObservations, 2);
  });

  test('same GTIN with conflicting explicit lots stays independent', () {
    final graph = buildOfflineEvidenceGraph([
      _frame(
        text: 'DOLO 650 PARACETAMOL TABLETS EXP 271031',
        barcode: '(01)09504000059118(17)271031(10)LOT7',
        sequence: 1,
      ),
      _frame(
        text: 'DOLO 650 PARACETAMOL TABLETS EXP 271031',
        barcode: '(01)09504000059118(17)271031(10)LOT8',
        sequence: 2,
      ),
    ]);
    expect(graph.independentObservations, 2);
  });

  test('same GTIN does not collapse complementary front and back views', () {
    final graph = buildOfflineEvidenceGraph([
      _frame(
        text: 'DOLO 650 PARACETAMOL TABLETS',
        barcode: '09504000059118',
        sequence: 1,
      ),
      _frame(
        text: 'COMPOSITION PARACETAMOL 650 MG BATCH LOT7 EXP 10 2027',
        barcode: '09504000059118',
        sequence: 2,
      ),
    ]);
    expect(graph.independentObservations, 2);
  });
}
