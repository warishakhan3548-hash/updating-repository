import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_date_parser.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V32', () {
    test('dosage-form aliases share one deterministic vocabulary', () {
      expect(normalizeForm('Dispersible Tablets'), 'Tablet');
      expect(normalizeForm('Soft Gel Capsule'), 'Capsule');
      expect(normalizeForm('Eye Ointment'), 'Ointment');
      expect(normalizeForm('Oral Drops'), 'Drops');

      final result = const MedicineUnderstandingEngine().understand(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'CALPOL\nParacetamol I.P. 500 mg\nDISPERSIBLE TABLETS',
            quality: .95,
          ),
        ],
      );
      expect(result.drafts, hasLength(1));
      expect(result.drafts.single.form, 'Tablet');
    });

    test('common conservative date aliases own adjacent dates', () {
      expect(medicineManufacturingLabel.hasMatch('Date of Mfg: 04/2026'), isTrue);
      expect(medicineManufacturingLabel.hasMatch('MFR DATE 04/2026'), isTrue);
      expect(medicineExpiryLabel.hasMatch('E/D: 04/2028'), isTrue);
      expect(medicineExpiryLabel.hasMatch('XPRY 04/2028'), isTrue);
      expect(medicineExpiryLabel.hasMatch('EXPN. 04/2028'), isTrue);
    });

    test('punctuated MFD BY still extracts manufacturer without becoming name', () {
      final result = const MedicineUnderstandingEngine().understand(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'CALPOL\nMFD. BY: HEALTHWELL PHARMACEUTICALS PVT LTD',
            quality: .95,
          ),
        ],
      );
      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('calpol'));
      expect(draft.manufacturer.toLowerCase(), contains('healthwell'));
      expect(draft.name.toLowerCase(), isNot(contains('healthwell')));
    });

    test('semantic brand replaces a high-confidence legal-company false name', () {
      const frame = MedicineFrameEvidence(
        sequence: 7,
        text: 'HEALWELL BIOTECH LLP\nCALPOL\nParacetamol I.P. 120 mg/5 ml\nORAL SUSPENSION',
        quality: .97,
      );
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          MedicineScanDraft(
            fields: const <String, ExtractedMedicineField>{
              'name': ExtractedMedicineField(
                value: 'HEALWELL BIOTECH LLP',
                confidence: .96,
                support: 1,
              ),
            },
            rawText: frame.text,
            searchKeywords: 'healwell biotech llp calpol',
            frameSequences: const <int>[7],
            overallConfidence: .96,
          ),
        ],
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[],
        referenceDate: DateTime.utc(2026, 9, 14),
      ).reconcile(baseline, const <MedicineFrameEvidence>[frame]);

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('calpol'));
      expect(draft.name.toLowerCase(), isNot(contains('healwell')));
      expect(draft.brand.toLowerCase(), contains('calpol'));
    });

    test('resolver V2 understands noisy pack roles without local or cloud AI', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 32,
              quality: .97,
              text: 'HEALWELL BIOTECH LLP\nCALPOL\nEach 5 ml contains Paracetamol I.P. 120 mg\nORAL SUSPENSION\nDate of Mfg: 04/2026\nE/D: 04/2028',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('calpol'));
      expect(draft.name.toLowerCase(), isNot(contains('healwell')));
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.strength.toLowerCase(), contains('120 mg/5 ml'));
      expect(draft.form, 'Suspension');
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });
  });
}
