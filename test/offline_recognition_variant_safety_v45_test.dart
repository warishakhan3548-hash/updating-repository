import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/offline_recognition_memory_service.dart';

const adult = MedicineKnowledgeEntry(
  name: 'Dolo',
  brand: 'Dolo',
  salt: 'Paracetamol',
  strength: '500 mg',
  form: 'Tablet',
  barcode: '1111111111111',
);

const child = MedicineKnowledgeEntry(
  name: 'Dolo',
  brand: 'Dolo',
  salt: 'Paracetamol',
  strength: '125 mg/5 mL',
  form: 'Suspension',
  barcode: '2222222222222',
);

String _identity(MedicineKnowledgeEntry item) => recognitionIdentityKey(
      name: item.name,
      brand: item.brand,
      salt: item.salt,
      strength: item.strength,
      form: item.form,
    );

void main() {
  group('adaptive recognition variant safety V45', () {
    test('current strength and form keep a shared OCR alias on its variant', () {
      final compatible = recognitionVariantCompatibleIdentityKeys(
        alias: 'D0L0',
        candidates: const <MedicineKnowledgeEntry>[adult, child],
        evidence: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            text: 'D0L0\nPARACETAMOL\n125 mg/5 mL\nORAL SUSPENSION',
          ),
        ],
      );

      expect(compatible, <String>{_identity(child)});
    });

    test('missing variant evidence abstains instead of inventing a winner', () {
      final compatible = recognitionVariantCompatibleIdentityKeys(
        alias: 'D0L0',
        candidates: const <MedicineKnowledgeEntry>[adult, child],
        evidence: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            text: 'D0L0\nPARACETAMOL',
          ),
        ],
      );

      expect(compatible, <String>{_identity(adult), _identity(child)});
    });

    test('variant evidence from another frame cannot leak across medicines', () {
      final compatible = recognitionVariantCompatibleIdentityKeys(
        alias: 'D0L0',
        candidates: const <MedicineKnowledgeEntry>[adult, child],
        evidence: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            text: 'D0L0\nPARACETAMOL',
          ),
          MedicineFrameEvidence(
            sequence: 1,
            quality: .95,
            text: 'OTHER BRAND\n125 mg/5 mL\nORAL SUSPENSION',
          ),
        ],
      );

      expect(compatible, <String>{_identity(adult), _identity(child)});
    });

    test('barcode and contradictory text make adaptive memory abstain', () {
      final compatible = recognitionVariantCompatibleIdentityKeys(
        alias: 'D0L0',
        candidates: const <MedicineKnowledgeEntry>[adult, child],
        evidence: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            barcode: '1111111111111',
            text: 'D0L0\n125 mg/5 mL\nORAL SUSPENSION',
          ),
        ],
      );

      expect(compatible, isEmpty);
    });

    test('exact barcode can disambiguate when text has no variant conflict', () {
      final compatible = recognitionVariantCompatibleIdentityKeys(
        alias: 'D0L0',
        candidates: const <MedicineKnowledgeEntry>[adult, child],
        evidence: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            barcode: '1111111111111',
            text: 'D0L0\nPARACETAMOL',
          ),
        ],
      );

      expect(compatible, <String>{_identity(adult)});
    });
  });
}
