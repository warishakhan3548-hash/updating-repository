import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

MedicineTextLineEvidence _line(String text, double top) =>
    MedicineTextLineEvidence(
      text: text,
      left: 12,
      top: top,
      width: 240,
      height: 22,
    );

ExtractedMedicineField _field(String value, double confidence) =>
    ExtractedMedicineField(
      value: value,
      confidence: confidence,
      support: 1,
    );

void main() {
  group('medicine evidence integrity V27', () {
    test('layout-only OCR reaches the deterministic V2 parser', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            MedicineFrameEvidence(
              sequence: 7,
              quality: .94,
              layoutLines: <MedicineTextLineEvidence>[
                _line('CROCIN ADVANCE', 10),
                _line('Paracetamol Tablets IP 500 mg', 42),
                _line('MFG 05/2026', 74),
                _line('EXP 04/2028', 106),
              ],
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.strength.toLowerCase(), contains('500 mg'));
      expect(draft.mfg, '2026-05');
      expect(draft.expiry, '2028-04');
    });

    test('duplicate frame sequences cannot overwrite independent OCR evidence', () {
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          MedicineScanDraft(
            fields: <String, ExtractedMedicineField>{
              'name': _field('Crocin Advance', .91),
            },
            rawText: '''
CROCIN ADVANCE
GENERIC NAME
Paracetamol
500 mg
MFG 05/2026
EXP 04/2028
''',
            searchKeywords: 'crocin advance paracetamol 500 mg',
            frameSequences: const <int>[0],
            overallConfidence: .74,
          ),
        ],
      );

      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[],
        referenceDate: DateTime.utc(2026, 9, 14),
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            text: 'GENERIC NAME\nParacetamol\n500 mg',
          ),
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            text: 'MFG 05/2026\nEXP 04/2028',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.salt.toLowerCase(), 'paracetamol');
      expect(draft.strength.toLowerCase(), '500 mg');
      expect(draft.mfg, '2026-05');
      expect(draft.expiry, '2028-04');
    });
  });
}
