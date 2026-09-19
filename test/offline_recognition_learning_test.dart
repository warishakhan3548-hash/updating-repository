import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/offline_recognition_memory_service.dart';

MedicineScanDraft _draft({
  required String rawText,
  String name = '',
  String brand = '',
  String salt = '',
  String strength = '',
  String form = 'Tablet',
}) => MedicineScanDraft(
  fields: <String, ExtractedMedicineField>{
    if (name.isNotEmpty)
      'name': ExtractedMedicineField(
        value: name,
        confidence: .72,
        support: 1,
      ),
    if (brand.isNotEmpty)
      'brand': ExtractedMedicineField(
        value: brand,
        confidence: .72,
        support: 1,
      ),
    if (salt.isNotEmpty)
      'salt': ExtractedMedicineField(
        value: salt,
        confidence: .68,
        support: 1,
      ),
    if (strength.isNotEmpty)
      'strength': ExtractedMedicineField(
        value: strength,
        confidence: .80,
        support: 1,
      ),
    if (form.isNotEmpty)
      'form': ExtractedMedicineField(
        value: form,
        confidence: .80,
        support: 1,
      ),
  },
  rawText: rawText,
  searchKeywords: '',
  frameSequences: const <int>[0],
  overallConfidence: .70,
);

Medicine _confirmed({
  String name = 'Prednil',
  String brand = 'Prednil',
  String salt = 'Prednisolone',
  String strength = '10 mg',
  String form = 'Tablet',
}) => Medicine(
  id: 'm1',
  name: name,
  brand: brand,
  salt: salt,
  strength: strength,
  form: form,
);

void main() {
  group('field-aware recognition learning', () {
    test('learns a damaged salt spelling only from explicit raw OCR evidence', () {
      final aliases = deriveLearnableSaltAliases(
        _draft(
          rawText: 'PREDNIL\nCOMPOSITION\nPDSNOL 10 mg\nTABLETS',
          name: 'Prednil',
          brand: 'Prednil',
          salt: 'PDSNOL',
          strength: '10 mg',
        ),
        _confirmed(),
      );

      expect(aliases, contains('PDSNOL'));
    });

    test('does not learn a semantic jump between unrelated ingredients', () {
      final aliases = deriveLearnableSaltAliases(
        _draft(
          rawText: 'PARACETAMOL 10 mg',
          salt: 'Paracetamol',
          strength: '10 mg',
        ),
        _confirmed(),
      );

      expect(aliases, isEmpty);
    });

    test('does not generalize a one-letter clue into an ingredient', () {
      final aliases = deriveLearnableSaltAliases(
        _draft(rawText: 'P 10 mg', salt: 'P', strength: '10 mg'),
        _confirmed(),
      );

      expect(aliases, isEmpty);
    });

    test('does not learn a correction that was never visible in OCR', () {
      final aliases = deriveLearnableSaltAliases(
        _draft(
          rawText: 'PREDNIL\nTABLETS 10 mg',
          salt: 'PDSNOL',
          strength: '10 mg',
        ),
        _confirmed(),
      );

      expect(aliases, isEmpty);
    });

    test('flat correction memory abstains for combination ingredients', () {
      final aliases = deriveLearnableSaltAliases(
        _draft(
          rawText: 'AMOXYCILLIN + CLAVULANIC ACID',
          salt: 'Amoxycillin + Clavulanic Acid',
        ),
        _confirmed(salt: 'Amoxicillin + Clavulanic Acid'),
      );

      expect(aliases, isEmpty);
    });

    test('knowledge message roundtrip preserves field-scoped salt aliases', () {
      const entry = MedicineKnowledgeEntry(
        name: 'Prednil',
        brand: 'Prednil',
        salt: 'Prednisolone',
        strength: '10 mg',
        form: 'Tablet',
        saltOcrAliases: <String>['PDSNOL'],
      );

      final restored = MedicineKnowledgeEntry.fromMessage(entry.toMessage());

      expect(restored.saltOcrAliases, <String>['PDSNOL']);
      expect(restored.ocrAliases, isEmpty);
    });

    test('exact learned salt correction canonicalizes the same OCR mistake', () {
      final result = MedicineUnderstandingEngine(
        knowledge: const <MedicineKnowledgeEntry>[
          MedicineKnowledgeEntry(
            name: 'Prednil',
            brand: 'Prednil',
            salt: 'Prednisolone',
            strength: '10 mg',
            form: 'Tablet',
            saltOcrAliases: <String>['PDSNOL'],
          ),
        ],
      ).understand(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 0,
          quality: .95,
          text: 'PREDNIL\nCOMPOSITION\nPDSNOL 10 mg\nTABLETS',
        ),
      ]);

      final draft = result.drafts.single;
      expect(draft.salt, 'Prednisolone');
      expect(draft.field('salt').conflicted, isFalse);
    });

    test('colliding learned salt aliases abstain instead of guessing', () {
      final result = MedicineUnderstandingEngine(
        knowledge: const <MedicineKnowledgeEntry>[
          MedicineKnowledgeEntry(
            name: 'Alpha One',
            brand: 'Alpha One',
            salt: 'Ingredient One',
            strength: '10 mg',
            form: 'Tablet',
            saltOcrAliases: <String>['ZXCVBN'],
          ),
          MedicineKnowledgeEntry(
            name: 'Alpha Two',
            brand: 'Alpha Two',
            salt: 'Ingredient Two',
            strength: '10 mg',
            form: 'Tablet',
            saltOcrAliases: <String>['ZXCVBN'],
          ),
        ],
      ).understand(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 0,
          quality: .95,
          text: 'COMPOSITION\nZXCVBN 10 mg\nTABLETS',
        ),
      ]);

      final salt = result.drafts.single.salt;
      expect(salt, isNot('Ingredient One'));
      expect(salt, isNot('Ingredient Two'));
    });
  });
}
