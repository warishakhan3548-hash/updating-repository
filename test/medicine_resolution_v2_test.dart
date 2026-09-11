import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_scan_commit.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';

void main() {
  group('Aaris Medicine Resolver V2', () {
    test('locks one coherent master product from noisy OCR', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              quality: .94,
              text: '''
D O L O 65O
Paracetamol Tablets IP 650 mg
TABLETS
''',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': <Map<String, Object?>>[
            const CanonicalMedicineProduct(
              productId: 'in:dolo:650:tablet',
              revision: 481,
              name: 'Dolo',
              brand: 'Dolo',
              salt: 'Paracetamol',
              strength: '650 mg',
              form: 'Tablet',
              manufacturer: 'Micro Labs Limited',
              aliases: <String>['Dolo 650'],
              ocrAliases: <String>['D0L0', 'DOL0'],
              source: 'verified-india-catalog',
              verified: true,
            ).toMessage(),
          ],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Dolo');
      expect(draft.brand, 'Dolo');
      expect(draft.salt, 'Paracetamol');
      expect(draft.strength.toLowerCase(), '650 mg');
      expect(draft.form, 'Tablet');
      expect(draft.field('strength').conflicted, isFalse);
    });

    test('does not create a Dolo 650 plus 500 mg hybrid', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              quality: .96,
              text: '''
DOLO 650
Paracetamol Tablets IP 500 mg
TABLETS
''',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': <Map<String, Object?>>[
            const CanonicalMedicineProduct(
              productId: 'in:dolo:650:tablet',
              revision: 482,
              name: 'Dolo',
              brand: 'Dolo',
              salt: 'Paracetamol',
              strength: '650 mg',
              form: 'Tablet',
              verified: true,
            ).toMessage(),
          ],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.strength.toLowerCase(), '500 mg');
      expect(draft.field('strength').conflicted, isTrue);
      expect(scanQuickIdentityReady(draft), isFalse);
    });

    test('promotes validated GS1 traceability above noisy OCR fields', () {
      const gs1 = ']d2010890123456789010LOT7\u001d1126081517280731';
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              barcode: gs1,
              text: '''
TESTMED
Paracetamol Tablets IP 650 mg
TABLETS
MFG 08/2026 EXP 07/2028
''',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.barcode, '08901234567890');
      expect(draft.batchNumber, 'LOT7');
      expect(draft.mfg, '2026-08-15');
      expect(draft.expiry, '2028-07-31');
      expect(draft.field('expiry').confidence, greaterThan(.99));
    });

    test('bare brand with two product variants remains unresolved', () {
      final local = <MedicineKnowledgeEntry>[
        const MedicineKnowledgeEntry(
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '500 mg',
          form: 'Tablet',
        ),
        const MedicineKnowledgeEntry(
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
      ];
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 0,
              text: 'DOLO\nTABLETS',
            ).toMessage(),
          ],
          'knowledge': local.map((value) => value.toMessage()).toList(),
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Dolo');
      expect(draft.strength, isEmpty);
      expect(scanQuickIdentityReady(draft), isFalse);
    });
  });
}
