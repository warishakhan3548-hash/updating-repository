import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_scan_commit.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('named full dates', () {
    test('accepts month-day-year without reducing it to month-year', () {
      for (final entry in <String, String>{
        'EXP APR 30, 2028': '2028-04-30',
        'MFG January 5 2026': '2026-01-05',
        'EXP फरवरी २९, २०२८': '2028-02-29',
        'EXP APR 2028': '2028-04',
        'MFG 05 APR 2026': '2026-04-05',
        'EXP 2028 APR 30': '2028-04-30',
        'MFG 05 04 2026': '2026-04-05',
        'EXP 05042028': '2028-04-05',
      }.entries) {
        expect(parseMedicineDateText(entry.key)?.value, entry.value,
            reason: entry.key);
      }
    });

    test('invalid full surfaces cannot fall back to a valid date tail', () {
      for (final value in <String>[
        'EXP APR 31, 2028',
        'EXP FEB 29, 2027',
        'EXP APR 00, 2028',
        'EXP 31 APR 2028',
        'EXP 2028 APR 31',
      ]) {
        expect(parseMedicineDateText(value), isNull, reason: value);
      }
    });

    test('date roles retain full-date precision', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG APR 05, 2026\nEXP APR 30, 2028',
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(result.manufacturing?.date.value, '2026-04-05');
      expect(result.expiry?.date.value, '2028-04-30');
      expect(result.manufacturing?.date.monthOnly, isFalse);
      expect(result.expiry?.date.monthOnly, isFalse);
      expect(result.conflicted, isFalse);
    });

    test('full offline resolver uses the shared named-date grammar', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 1,
              quality: .98,
              text: 'BRAND NAME: CALPOL\n'
                  'GENERIC NAME: Paracetamol 500 mg\n'
                  'TABLETS\nMFG APR 05, 2026\nEXP APR 30, 2028',
            ).toMessage(),
          ],
        }),
      );
      expect(result.drafts, hasLength(1));
      expect(result.drafts.single.mfg, '2026-04-05');
      expect(result.drafts.single.expiry, '2028-04-30');
      expect(result.drafts.single.mfgMonthOnly, isFalse);
      expect(result.drafts.single.expiryMonthOnly, isFalse);
    });
  });

  group('semantic evidence ownership', () {
    const composition = 'COMPOSITION\nAmlodipine I.P.\n5 mg\n'
        'Bisoprolol fumarate I.P.\n5 mg\nEXCIPIENTS q.s.';

    test('equal doses retain separate ingredient ownership in raw OCR', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(text: composition),
      ]);
      expect(result.salt.toLowerCase(), 'amlodipine + bisoprolol fumarate');
      expect(result.strength, '5 mg + 5 mg');
      expect(result.components.map((component) => component.support), [1, 1]);
      expect(result.compositionConflicted, isFalse);
    });

    test('equal dose rows at distinct positions survive shuffled layout', () {
      const texts = <String>[
        'COMPOSITION', 'Amlodipine I.P.', '5 mg',
        'Bisoprolol fumarate I.P.', '5 mg', 'EXCIPIENTS q.s.',
      ];
      final lines = <MedicineTextLineEvidence>[
        for (var index = 0; index < texts.length; index++)
          MedicineTextLineEvidence(
            text: texts[index],
            left: 10,
            top: index * 20.0,
            width: 180,
            height: 10,
          ),
      ];
      final result = inferMedicineSemanticRoles(<MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: composition,
          layoutLines: <MedicineTextLineEvidence>[
            ...lines.reversed,
            lines[2], // duplicate observation of the same physical dose
          ],
        ),
      ]);
      expect(result.salt.toLowerCase(), 'amlodipine + bisoprolol fumarate');
      expect(result.strength, '5 mg + 5 mg');
      expect(result.components.map((component) => component.support), [1, 1]);
    });

    test('overlapping row tolerances are invariant to recognizer order', () {
      const lines = <MedicineTextLineEvidence>[
        MedicineTextLineEvidence(
          text: 'BRAND NAME', left: 100, top: 0, width: 90, height: 10,
        ),
        MedicineTextLineEvidence(
          text: 'CROCIN', left: 50, top: 5, width: 70, height: 10,
        ),
        MedicineTextLineEvidence(
          text: 'GENERIC NAME: Paracetamol 650 mg',
          left: 0, top: 10, width: 200, height: 10,
        ),
      ];
      List<Object>? expected;
      for (final order in const <List<int>>[
        [0, 1, 2], [0, 2, 1], [1, 0, 2],
        [1, 2, 0], [2, 0, 1], [2, 1, 0],
      ]) {
        final result = inferMedicineSemanticRoles(<MedicineFrameEvidence>[
          MedicineFrameEvidence(
            layoutLines: order.map((index) => lines[index]).toList(),
          ),
        ]);
        final signature = <Object>[
          result.brand, result.brandConfidence, result.genericName,
          result.genericConfidence, result.salt, result.strength,
          result.conflicted, result.compositionConflicted,
        ];
        expected ??= signature;
        expect(signature, expected, reason: order.toString());
      }
    });

    test('two rules observing one brand do not create independent support', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: 'BRAND NAME: CALPOL\nCALPOL\n'
              'GENERIC NAME: Paracetamol 500 mg\nTABLETS',
        ),
      ]);
      expect(result.brand.toLowerCase(), 'calpol');
      expect(result.brandConfidence, closeTo(.97, .000001));
    });

    test('conflicting doses in one frame abstain without erasing the brand', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: 'BRAND NAME: CALPOL\nCOMPOSITION\n'
              'Paracetamol 500 mg\nParacetamol 650 mg\nTABLETS',
        ),
      ]);
      expect(result.brand.toLowerCase(), 'calpol');
      expect(result.conflicted, isFalse);
      expect(result.compositionConflicted, isTrue);
      expect(result.components, isEmpty);
      expect(result.isEmpty, isFalse);
    });

    test('conflict-only resolution is not discarded as empty', () {
      expect(
        const MedicineSemanticResolution(compositionConflicted: true).isEmpty,
        isFalse,
      );
      expect(const MedicineSemanticResolution(conflicted: true).isEmpty, isFalse);
      expect(const MedicineSemanticResolution().isEmpty, isTrue);
    });

    test('raw evidence conflict blocks the production one-tap path', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              text: 'BRAND NAME: CALPOL\nCOMPOSITION\n'
                  'Paracetamol 500 mg\nParacetamol 650 mg\nTABLETS',
              quality: .98,
              sequence: 1,
            ).toMessage(),
          ],
        }),
      );
      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.field('salt').conflicted, isTrue);
      expect(draft.field('strength').conflicted, isTrue);
      expect(scanQuickIdentityReady(draft), isFalse);
    });

    test('source conflict survives confident baseline and catalogue matching', () {
      const raw = 'BRAND NAME: CALPOL\nCOMPOSITION\n'
          'Paracetamol 500 mg\nParacetamol 650 mg\nTABLETS';
      const baseline = MedicineScanDraft(
        fields: <String, ExtractedMedicineField>{
          'name': ExtractedMedicineField(value: 'Calpol', confidence: .97),
          'brand': ExtractedMedicineField(value: 'Calpol', confidence: .97),
          'salt': ExtractedMedicineField(value: 'Paracetamol', confidence: .97),
          'strength': ExtractedMedicineField(value: '500 mg', confidence: .97),
          'form': ExtractedMedicineField(value: 'Tablet', confidence: .97),
          'barcode': ExtractedMedicineField(
            value: '8901234567890', confidence: .99,
          ),
        },
        rawText: raw,
        searchKeywords: '',
        frameSequences: <int>[1],
        overallConfidence: .97,
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[
          CanonicalMedicineProduct(
            productId: 'fixture:calpol',
            revision: 1,
            name: 'Calpol',
            brand: 'Calpol',
            salt: 'Paracetamol',
            strength: '500 mg',
            form: 'Tablet',
            barcodes: <String>['8901234567890'],
            verified: true,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      ).reconcile(
        const MedicineUnderstandingResult(drafts: <MedicineScanDraft>[baseline]),
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: raw, sequence: 1, barcode: '8901234567890',
          ),
        ],
      );
      final draft = result.drafts.single;
      expect(draft.field('salt').conflicted, isTrue);
      expect(draft.field('strength').conflicted, isTrue);
      expect(draft.field('brand').conflicted, isFalse);
      expect(draft.brand.toLowerCase(), 'calpol');
      expect(scanQuickIdentityReady(draft), isFalse);
      expect(draft.needsReview, isTrue);
    });
  });
}
