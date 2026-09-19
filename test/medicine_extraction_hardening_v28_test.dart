import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedMedicineField _field(String value, double confidence) =>
    ExtractedMedicineField(
      value: value,
      confidence: confidence,
      support: 1,
    );

void main() {
  group('medicine extraction hardening V28', () {
    test('text-only V2 evidence receives the same OCR canonicalization as camera input', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 11,
              quality: .94,
              text: 'ＣＲＯＣＩＮ\nPARACETAMOL I.P. ５OO ｍｇ\nMFG ０５／２０２６\nEXP ０４／２０２８',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('crocin'));
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.strength.toLowerCase(), contains('500 mg'));
      expect(draft.mfg, '2026-05');
      expect(draft.expiry, '2028-04');
      expect(draft.rawText, isNot(contains('５')));
      expect(draft.rawText, isNot(contains('ｍｇ')));
    });

    test('layout geometry is retained while its text is canonicalized', () {
      MedicineTextLineEvidence line(String text, double top) =>
          MedicineTextLineEvidence(
            text: text,
            left: 10,
            top: top,
            width: 220,
            height: 20,
          );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'referenceDate': DateTime.utc(2026, 9, 14).toIso8601String(),
          'evidence': <Map<String, Object?>>[
            MedicineFrameEvidence(
              sequence: 12,
              quality: .95,
              layoutLines: <MedicineTextLineEvidence>[
                line('ＣＲＯＣＩＮ', 8),
                line('PARACETAMOL I.P. ５OO ｍｇ', 36),
                line('MFG ０５／２０２６', 64),
                line('EXP ０４／２０２８', 92),
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

    test('microgram spellings cannot create a false strength conflict', () {
      final baseline = MedicineUnderstandingResult(
        drafts: <MedicineScanDraft>[
          MedicineScanDraft(
            fields: <String, ExtractedMedicineField>{
              'name': _field('Microdose', .95),
              'brand': _field('Microdose', .95),
              'salt': _field('Budesonide', .95),
              'strength': _field('500 ug', .95),
              'form': _field('Tablet', .95),
            },
            rawText: 'MICRODOSE\nBudesonide 500 ug\nTablet',
            searchKeywords: 'microdose budesonide 500 ug tablet',
            frameSequences: const <int>[0],
            overallConfidence: .95,
          ),
        ],
      );

      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[
          CanonicalMedicineProduct(
            productId: 'master:microdose-500mcg',
            revision: 1,
            name: 'Microdose',
            brand: 'Microdose',
            salt: 'Budesonide',
            strength: '500 µg',
            form: 'Tablet',
            verified: true,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      ).reconcile(
        baseline,
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            text: 'MICRODOSE\nBudesonide 500 ug\nTablet',
          ),
        ],
      );

      final strength = result.drafts.single.field('strength');
      expect(strength.conflicted, isFalse);
      expect(strength.value, '500 µg');
    });
  });
}
