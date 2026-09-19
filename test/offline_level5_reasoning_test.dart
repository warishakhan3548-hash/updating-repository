import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/offline_decision_reliability.dart';
import 'package:aaris_pharmacy/domain/offline_evidence_graph.dart';
import 'package:aaris_pharmacy/services/offline_recognition_memory_service.dart';

void main() {
  group('Level 5 offline evidence graph', () {
    test('near-duplicate video frames count as one observation', () {
      final graph = buildOfflineEvidenceGraph(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 1,
          quality: .84,
          text: 'DOLO 650\nParacetamol Tablets IP\nMicro Labs',
        ),
        MedicineFrameEvidence(
          sequence: 2,
          quality: .96,
          text: 'DOLO 65O\nParacetamol Tablets IP\nMicro Labs',
        ),
        MedicineFrameEvidence(
          sequence: 20,
          quality: .91,
          text: 'MICRO LABS LIMITED\nBatch AB12\nEXP 08/2028',
        ),
      ]);

      expect(graph.observedFrames, 3);
      expect(graph.independentObservations, 2);
      expect(graph.correlatedDuplicates, 1);
      expect(graph.groups.any((group) => group.support == 2), isTrue);
    });

    test('repeating the same frame cannot manufacture new evidence', () {
      final frames = List<MedicineFrameEvidence>.generate(
        10,
        (index) => MedicineFrameEvidence(
          sequence: index,
          quality: .90 + index / 1000,
          text: 'MONTEK LC\nMontelukast Levocetirizine\nTABLETS',
        ),
      );
      final graph = buildOfflineEvidenceGraph(frames);
      expect(graph.independentObservations, 1);
      expect(graph.groups.single.support, 10);
    });
  });

  group('Level 5 selective decision reliability', () {
    test('strong independent decision features pass the abstention gate', () {
      final result = assessOfflineDecisionReliability(
        winnerScore: .94,
        margin: .19,
        channels: 4,
        decisionMass: .61,
        evidenceQuality: .91,
        verified: true,
        hardConflicts: 0,
      );
      expect(result.acceptCanonicalLock, isTrue);
      expect(result.score, greaterThan(.80));
    });

    test('hard contradiction always rejects even an exact identifier', () {
      final result = assessOfflineDecisionReliability(
        winnerScore: .99,
        margin: 1,
        channels: 5,
        decisionMass: .90,
        evidenceQuality: .99,
        verified: true,
        hardConflicts: 1,
        exactBarcode: true,
      );
      expect(result.acceptCanonicalLock, isFalse);
      expect(result.score, 0);
    });

    test('weak single-channel evidence abstains', () {
      final result = assessOfflineDecisionReliability(
        winnerScore: .88,
        margin: .20,
        channels: 1,
        decisionMass: .30,
        evidenceQuality: .75,
        verified: true,
        hardConflicts: 0,
      );
      expect(result.acceptCanonicalLock, isFalse);
    });
  });

  group('Level 5 pharmacist-confirmed OCR learning', () {
    test('learns identity-like OCR variants but not ingredient text', () {
      final draft = MedicineScanDraft(
        fields: const <String, ExtractedMedicineField>{},
        rawText: 'D0L0 650\nParacetamol Tablets IP 650 mg\nMICRO LABS',
        searchKeywords: '',
        frameSequences: const <int>[0],
      );
      final confirmed = Medicine(
        id: 'confirmed-1',
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
      );

      final aliases = deriveLearnableIdentityAliases(draft, confirmed);
      expect(aliases, contains('d0l0'));
      expect(aliases, isNot(contains('paracetamol')));
      expect(aliases.length, lessThanOrEqualTo(8));
    });

    test('identity key changes when safety-relevant variant changes', () {
      final first = recognitionIdentityKey(
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
      );
      final second = recognitionIdentityKey(
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '500 mg',
        form: 'Tablet',
      );
      expect(first, isNotEmpty);
      expect(first, isNot(second));
    });
  });
}
