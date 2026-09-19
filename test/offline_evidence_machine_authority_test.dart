import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/offline_evidence_graph.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ambiguous multi-product code set never collapses into singleton product', () {
    const productA = '09504000059118';
    const productB = '09501101530003';
    final graph = buildOfflineEvidenceGraph(const <MedicineFrameEvidence>[
      MedicineFrameEvidence(
        text: 'DOLO 650 PARACETAMOL TABLETS',
        barcodes: <String>[productA, productB],
        sequence: 1,
      ),
      MedicineFrameEvidence(
        text: 'DOLO 650 PARACETAMOL TABLETS',
        barcode: productA,
        sequence: 2,
      ),
    ]);

    expect(graph.independentObservations, 2);
  });

  test('same unambiguous GTIN can still collapse true repeated observation', () {
    const product = '09504000059118';
    final graph = buildOfflineEvidenceGraph(const <MedicineFrameEvidence>[
      MedicineFrameEvidence(
        text: 'DOLO 650 PARACETAMOL TABLETS',
        barcode: product,
        sequence: 1,
      ),
      MedicineFrameEvidence(
        text: 'DOLO 650 PARACETAMOL TABLETS',
        barcode: product,
        sequence: 2,
      ),
    ]);

    expect(graph.independentObservations, 1);
  });
}
