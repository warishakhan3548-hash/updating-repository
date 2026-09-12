import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedMedicineField _field(String value, {double confidence = .95}) =>
    ExtractedMedicineField(value: value, confidence: confidence, support: 2);

MedicineScanDraft _draft({
  required String name,
  required String salt,
  String strength = '',
  String form = 'Tablet',
  String barcode = '',
}) {
  final fields = <String, ExtractedMedicineField>{
    'name': _field(name, confidence: .97),
    if (salt.isNotEmpty) 'salt': _field(salt, confidence: .94),
    if (strength.isNotEmpty) 'strength': _field(strength, confidence: .94),
    if (form.isNotEmpty) 'form': _field(form, confidence: .93),
    if (barcode.isNotEmpty) 'barcode': _field(barcode, confidence: .99),
  };
  return MedicineScanDraft(
    fields: fields,
    rawText: [
      name,
      salt,
      strength,
      form,
      barcode,
    ].where((value) => value.isNotEmpty).join('\n'),
    searchKeywords: [
      name,
      salt,
      strength,
      form,
    ].where((value) => value.isNotEmpty).join(' '),
    frameSequences: const <int>[0],
    overallConfidence: .95,
  );
}

MedicineUnderstandingResult _resolve(
  MedicineScanDraft draft,
  List<CanonicalMedicineProduct> catalogue,
) {
  return MedicineProductResolverV2(
    localKnowledge: const <MedicineKnowledgeEntry>[],
    catalogue: catalogue,
  ).reconcile(
    MedicineUnderstandingResult(drafts: <MedicineScanDraft>[draft]),
    <MedicineFrameEvidence>[
      MedicineFrameEvidence(
        sequence: 0,
        quality: .96,
        text: draft.rawText,
        barcodes: draft.barcode.isEmpty
            ? const <String>[]
            : <String>[draft.barcode],
      ),
    ],
  );
}

void main() {
  group('Aaris Offline V12 counterfactual variant reasoning', () {
    const base = CanonicalMedicineProduct(
      productId: 'rx:cardibeta:25',
      revision: 1,
      name: 'Cardibeta',
      brand: 'Cardibeta',
      salt: 'Metoprolol Succinate',
      strength: '25 mg',
      form: 'Tablet',
      barcodes: <String>['08901234567890'],
      verified: true,
    );
    const plus = CanonicalMedicineProduct(
      productId: 'rx:cardibeta-plus:50',
      revision: 1,
      name: 'Cardibeta Plus',
      brand: 'Cardibeta Plus',
      salt: 'Metoprolol Succinate',
      strength: '50 mg',
      form: 'Tablet',
      barcodes: <String>['08901234567906'],
      verified: true,
    );

    test(
      'missing strength cannot canonicalize a plausible same-family variant',
      () {
        final resolved = _resolve(
          _draft(name: 'Cardibeta', salt: 'Metoprolol Succinate'),
          const <CanonicalMedicineProduct>[base, plus],
        );

        final draft = resolved.drafts.single;
        expect(draft.strength, isEmpty);
        expect(draft.overallConfidence, lessThanOrEqualTo(.77));
      },
    );

    test('reliable discriminating strength unlocks the correct variant', () {
      final resolved = _resolve(
        _draft(
          name: 'Cardibeta',
          salt: 'Metoprolol Succinate',
          strength: '25 mg',
        ),
        const <CanonicalMedicineProduct>[base, plus],
      );

      final draft = resolved.drafts.single;
      expect(draft.strength, '25 mg');
      expect(draft.brand.toLowerCase(), 'cardibeta');
      expect(draft.overallConfidence, greaterThan(.80));
    });

    test('verified exact barcode remains the highest-authority bypass', () {
      final resolved = _resolve(
        _draft(
          name: 'Cardibeta',
          salt: 'Metoprolol Succinate',
          barcode: '08901234567890',
        ),
        const <CanonicalMedicineProduct>[base, plus],
      );

      expect(resolved.drafts.single.strength, '25 mg');
    });

    test(
      'missing salt cannot choose between same-family composition variants',
      () {
        const mono = CanonicalMedicineProduct(
          productId: 'rx:neurocalm:mono',
          revision: 1,
          name: 'Neurocalm',
          brand: 'Neurocalm',
          salt: 'Pregabalin',
          strength: '75 mg',
          form: 'Capsule',
          verified: true,
        );
        const combo = CanonicalMedicineProduct(
          productId: 'rx:neurocalm-plus',
          revision: 1,
          name: 'Neurocalm Plus',
          brand: 'Neurocalm Plus',
          salt: 'Pregabalin + Methylcobalamin',
          strength: '75 mg',
          form: 'Capsule',
          verified: true,
        );

        final resolved = _resolve(
          _draft(
            name: 'Neurocalm',
            salt: '',
            strength: '75 mg',
            form: 'Capsule',
          ),
          const <CanonicalMedicineProduct>[mono, combo],
        );

        expect(resolved.drafts.single.salt, isEmpty);
        expect(
          resolved.drafts.single.overallConfidence,
          lessThanOrEqualTo(.77),
        );
      },
    );
  });
}
