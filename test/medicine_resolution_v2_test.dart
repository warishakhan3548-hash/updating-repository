import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/intake_resolution.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_scan_commit.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';

ExtractedMedicineField _field(
  String value, {
  double confidence = .95,
  bool conflicted = false,
}) => ExtractedMedicineField(
  value: value,
  confidence: confidence,
  support: 2,
  conflicted: conflicted,
);

MedicineScanDraft _doloDraft({
  String barcode = '',
  double barcodeConfidence = .95,
  bool barcodeConflicted = false,
  double overallConfidence = .95,
}) => MedicineScanDraft(
  fields: <String, ExtractedMedicineField>{
    'name': _field('Dolo'),
    'brand': _field('Dolo'),
    'salt': _field('Paracetamol'),
    'strength': _field('650 mg'),
    'form': _field('Tablet'),
    if (barcode.isNotEmpty)
      'barcode': _field(
        barcode,
        confidence: barcodeConfidence,
        conflicted: barcodeConflicted,
      ),
  },
  rawText: 'DOLO 650\nParacetamol Tablets IP 650 mg\nTABLETS',
  searchKeywords: 'dolo paracetamol 650 mg tablet',
  frameSequences: const <int>[0],
  overallConfidence: overallConfidence,
);

const _newStock = IntakeResolution(
  kind: IntakeResolutionKind.newStock,
  candidateStockIds: <String>[],
  reason: 'No existing stock.',
);

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

    test('marketing QR cannot veto a coherent product identity', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:dolo:650:tablet',
        revision: 500,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        barcodes: <String>['8901234567890'],
        verified: true,
      );
      final result =
          MedicineProductResolverV2(
            localKnowledge: const <MedicineKnowledgeEntry>[],
            catalogue: const <CanonicalMedicineProduct>[product],
          ).reconcile(
            MedicineUnderstandingResult(
              drafts: <MedicineScanDraft>[_doloDraft()],
            ),
            const <MedicineFrameEvidence>[
              MedicineFrameEvidence(
                sequence: 0,
                barcodes: <String>['https://example.invalid/promo/dolo'],
                text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
              ),
            ],
          );

      final draft = result.drafts.single;
      expect(draft.overallConfidence, greaterThan(.78));
      expect(
        draft.fields.values
            .where((field) => !field.isEmpty)
            .any((field) => field.conflicted),
        isFalse,
      );
      expect(draft.strength, '650 mg');
    });

    test('shop and master copies of one product corroborate, not compete', () {
      const local = MedicineKnowledgeEntry(
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
      );
      const master = CanonicalMedicineProduct(
        productId: 'in:dolo:650:tablet',
        revision: 501,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        verified: true,
      );
      final result =
          MedicineProductResolverV2(
            localKnowledge: const <MedicineKnowledgeEntry>[local],
            catalogue: const <CanonicalMedicineProduct>[master],
          ).reconcile(
            MedicineUnderstandingResult(
              drafts: <MedicineScanDraft>[_doloDraft()],
            ),
            const <MedicineFrameEvidence>[
              MedicineFrameEvidence(
                sequence: 0,
                text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
              ),
            ],
          );

      final draft = result.drafts.single;
      expect(draft.overallConfidence, greaterThan(.78));
      expect(draft.needsReview, isFalse);
      expect(draft.strength, '650 mg');
    });

    test('conflicted barcode cannot cross the one-tap stock boundary', () {
      final draft = _doloDraft(
        barcode: '8901234567890',
        barcodeConflicted: true,
      );

      expect(scanQuickAddDecision(draft, _newStock).allowed, isFalse);
      expect(() => medicineFromConfirmedScan(draft), throwsFormatException);
    });

    test('different verified GTIN stays a visible blocking conflict', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:dolo:650:tablet',
        revision: 502,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        barcodes: <String>['8902222222227'],
        verified: true,
      );
      final result =
          MedicineProductResolverV2(
            localKnowledge: const <MedicineKnowledgeEntry>[],
            catalogue: const <CanonicalMedicineProduct>[product],
          ).reconcile(
            MedicineUnderstandingResult(
              drafts: <MedicineScanDraft>[_doloDraft(barcode: '8901111111116')],
            ),
            const <MedicineFrameEvidence>[
              MedicineFrameEvidence(
                sequence: 0,
                barcode: '8901111111116',
                text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
              ),
            ],
          );

      final draft = result.drafts.single;
      expect(draft.overallConfidence, lessThan(.78));
      expect(scanQuickAddDecision(draft, _newStock).allowed, isFalse);
    });

    test('checksum-invalid numeric payload cannot veto coherent identity', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:dolo:650:tablet',
        revision: 503,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        barcodes: <String>['8902222222227'],
        verified: true,
      );
      final result =
          MedicineProductResolverV2(
            localKnowledge: const <MedicineKnowledgeEntry>[],
            catalogue: const <CanonicalMedicineProduct>[product],
          ).reconcile(
            MedicineUnderstandingResult(
              drafts: <MedicineScanDraft>[_doloDraft(barcode: '8901111111111')],
            ),
            const <MedicineFrameEvidence>[
              MedicineFrameEvidence(
                sequence: 0,
                barcode: '8901111111111',
                text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
              ),
            ],
          );

      final draft = result.drafts.single;
      expect(draft.overallConfidence, greaterThanOrEqualTo(.78));
      expect(scanQuickIdentityReady(draft), isTrue);
    });

    test(
      'adjacent OCR transposition still resolves a coherent verified product',
      () {
        const product = CanonicalMedicineProduct(
          productId: 'in:dolo:650:tablet:v6',
          revision: 601,
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
          verified: true,
        );
        final noisy = MedicineScanDraft(
          fields: <String, ExtractedMedicineField>{
            'name': _field('Dloo', confidence: .91),
            'brand': _field('Dloo', confidence: .91),
            'salt': _field('Paracetamol'),
            'strength': _field('650 mg'),
            'form': _field('Tablet'),
          },
          rawText: 'DLOO 650\nParacetamol Tablets IP 650 mg',
          searchKeywords: 'dloo paracetamol 650 mg tablet',
          frameSequences: const <int>[0],
          overallConfidence: .91,
        );
        final result =
            MedicineProductResolverV2(
              localKnowledge: const <MedicineKnowledgeEntry>[],
              catalogue: const <CanonicalMedicineProduct>[product],
            ).reconcile(
              MedicineUnderstandingResult(drafts: <MedicineScanDraft>[noisy]),
              const <MedicineFrameEvidence>[
                MedicineFrameEvidence(
                  sequence: 0,
                  quality: .94,
                  text: 'DLOO 650\nParacetamol Tablets IP 650 mg',
                ),
              ],
            );

        final draft = result.drafts.single;
        expect(draft.name, 'Dolo');
        expect(draft.strength, '650 mg');
        expect(draft.field('name').conflicted, isFalse);
      },
    );

    test(
      'unverified exact code cannot suppress a verified coherent product',
      () {
        const unverifiedCodeMatch = CanonicalMedicineProduct(
          productId: 'local:unknown-code-owner',
          revision: 602,
          name: 'Different Medicine',
          brand: 'Different',
          salt: 'Ibuprofen',
          strength: '400 mg',
          form: 'Tablet',
          barcodes: <String>['LOCAL-CODE-42'],
          verified: false,
        );
        const verifiedDolo = CanonicalMedicineProduct(
          productId: 'in:dolo:650:tablet:v6-verified',
          revision: 603,
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
          verified: true,
        );
        final result =
            MedicineProductResolverV2(
              localKnowledge: const <MedicineKnowledgeEntry>[],
              catalogue: const <CanonicalMedicineProduct>[
                unverifiedCodeMatch,
                verifiedDolo,
              ],
            ).reconcile(
              MedicineUnderstandingResult(
                drafts: <MedicineScanDraft>[
                  _doloDraft(barcode: 'LOCAL-CODE-42'),
                ],
              ),
              const <MedicineFrameEvidence>[
                MedicineFrameEvidence(
                  sequence: 0,
                  barcode: 'LOCAL-CODE-42',
                  text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
                ),
              ],
            );

        final draft = result.drafts.single;
        expect(draft.name, 'Dolo');
        expect(draft.salt, 'Paracetamol');
        expect(draft.strength, '650 mg');
        expect(draft.fields.values.any((field) => field.conflicted), isFalse);
      },
    );

    test('second valid GTIN blocks an otherwise exact barcode auto-lock', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:dolo:650:multi-gtin-guard',
        revision: 604,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        barcodes: <String>['8902222222227'],
        verified: true,
      );
      final result =
          MedicineProductResolverV2(
            localKnowledge: const <MedicineKnowledgeEntry>[],
            catalogue: const <CanonicalMedicineProduct>[product],
          ).reconcile(
            MedicineUnderstandingResult(
              drafts: <MedicineScanDraft>[_doloDraft(barcode: '8902222222227')],
            ),
            const <MedicineFrameEvidence>[
              MedicineFrameEvidence(
                sequence: 0,
                barcode: '8902222222227',
                barcodes: <String>['8901111111116'],
                text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
              ),
            ],
          );

      final draft = result.drafts.single;
      expect(draft.overallConfidence, lessThan(.78));
      expect(scanQuickAddDecision(draft, _newStock).allowed, isFalse);
    });
  });
}
