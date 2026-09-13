import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/gs1_healthcare.dart';
import 'package:aaris_pharmacy/domain/medicine_machine_code_safety.dart';
import 'package:aaris_pharmacy/domain/medicine_scan_guidance.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';

ExtractedMedicineField _field(
  String value, {
  double confidence = .92,
  bool conflicted = false,
}) => ExtractedMedicineField(
  value: value,
  confidence: confidence,
  support: 1,
  conflicted: conflicted,
);

MedicineScanDraft _draft({
  String name = 'Dolo',
  String brand = 'Dolo',
  String salt = 'Paracetamol',
  String strength = '650 mg',
  String form = 'Tablet',
  String expiry = '2027-10',
  String barcode = '',
  bool barcodeConflicted = false,
  double overall = .91,
}) => MedicineScanDraft(
  fields: <String, ExtractedMedicineField>{
    if (name.isNotEmpty) 'name': _field(name),
    if (brand.isNotEmpty) 'brand': _field(brand),
    if (salt.isNotEmpty) 'salt': _field(salt),
    if (strength.isNotEmpty) 'strength': _field(strength),
    if (form.isNotEmpty) 'form': _field(form),
    if (expiry.isNotEmpty) 'expiry': _field(expiry),
    if (barcode.isNotEmpty)
      'barcode': _field(barcode, conflicted: barcodeConflicted),
  },
  rawText: '$name\n$brand\n$salt $strength\n$form\nEXP $expiry',
  searchKeywords: '',
  frameSequences: const <int>[0],
  expiryMonthOnly: expiry.length == 7,
  overallConfidence: overall,
);

MedicineFrameEvidence _frame({
  required int sequence,
  required String text,
  String barcode = '',
  List<String> barcodes = const <String>[],
  double quality = .8,
}) => MedicineFrameEvidence(
  sequence: sequence,
  text: text,
  barcode: barcode,
  barcodes: barcodes,
  quality: quality,
);

void main() {
  group('machine-code safety', () {
    test('same GTIN in linear and GS1 forms is one product identity', () {
      const gs1 = ']d201095040000591181727103110LOT7';
      final assessment = assessMedicineMachineCodes(const <String>[
        '9504000059118',
        '09504000059118',
        gs1,
      ]);

      expect(assessment.ambiguous, isFalse);
      expect(assessment.singleTrustedProduct, '09504000059118');
    });

    test('equivalent linear GTIN representations collapse to one payload', () {
      final selection = selectSafeMedicineMachineCodes(const <String>[
        '9504000059118',
        '09504000059118',
      ]);

      expect(selection.ambiguousTrustedProductCodes, isFalse);
      expect(selection.payloads, hasLength(1));
      expect(
        canonicalTrustedMedicineProductKey(selection.payloads.single),
        '09504000059118',
      );
    });

    test('traceability-rich GS1 wins over equivalent plain GTIN', () {
      const gs1 = ']d201095040000591181727103110LOT7';
      final selection = selectSafeMedicineMachineCodes(const <String>[
        '09504000059118',
        gs1,
      ]);

      expect(selection.ambiguousTrustedProductCodes, isFalse);
      expect(selection.payloads, <String>[gs1]);
    });

    test('two independently valid GTINs are ambiguous', () {
      final assessment = assessMedicineMachineCodes(const <String>[
        '09504000059118',
        '09501101530003',
      ]);

      expect(assessment.ambiguous, isTrue);
      expect(assessment.trustedProductKeys, hasLength(2));
    });

    test('ambiguous source marker survives as explicit safety evidence', () {
      expect(
        medicineMachineCodeSourceIsAmbiguous(
          'Captured still $ambiguousMedicineMachineCodesMarker',
        ),
        isTrue,
      );
      expect(medicineMachineCodeSourceIsAmbiguous('Captured still'), isFalse);
    });

    test('marketing QR and invalid numeric payload gain no product authority', () {
      final assessment = assessMedicineMachineCodes(const <String>[
        'https://example.invalid/promo',
        '8901111111111',
      ]);

      expect(assessment.hasTrustedProduct, isFalse);
    });
  });

  group('GS1 transport normalization', () {
    test('visible GS token preserves variable lot then expiry', () {
      final parsed = parseGs1HealthcareBarcode(
        ']d2010950400005911810LOT7<GS>17271031',
      );

      expect(parsed, isNotNull);
      expect(parsed!.gtin, '09504000059118');
      expect(parsed.batchLot, 'LOT7');
      expect(parsed.expiryYyMmDd, '271031');
    });

    test('unicode control-picture GS is accepted without guessing punctuation', () {
      final parsed = parseGs1HealthcareBarcode(
        ']d2010950400005911810LOT7\u241d17271031',
      );

      expect(parsed, isNotNull);
      expect(parsed!.batchLot, 'LOT7');
      expect(parsed.expiryYyMmDd, '271031');
    });
  });

  group('single-pack evidence reservoir', () {
    test('exact duplicate live frames collapse and keep better capture', () {
      final first = _frame(
        sequence: 1,
        text: 'DOLO 650\nParacetamol 650 mg',
        barcode: '09504000059118',
        quality: .42,
      );
      final better = _frame(
        sequence: 2,
        text: 'DOLO 650   Paracetamol 650 mg',
        barcode: '09504000059118',
        quality: .91,
      );

      final window = mergeSinglePackMedicineEvidence(<MedicineFrameEvidence>[
        first,
      ], better);

      expect(window.startedNewPack, isFalse);
      expect(window.frames, hasLength(1));
      expect(window.frames.single.sequence, 2);
      expect(window.frames.single.quality, .91);
    });

    test('safety-critical punctuation difference is never exact-deduplicated', () {
      final window = mergeSinglePackMedicineEvidence(<MedicineFrameEvidence>[
        _frame(sequence: 1, text: 'Ingredient 0.5 mg'),
      ], _frame(sequence: 2, text: 'Ingredient 0/5 mg'));

      expect(window.frames, hasLength(2));
    });

    test('ambiguous multi-GTIN frame cannot force a pack switch', () {
      final window = mergeSinglePackMedicineEvidence(<MedicineFrameEvidence>[
        _frame(
          sequence: 1,
          text: 'front',
          barcode: '09504000059118',
        ),
      ], _frame(
        sequence: 2,
        text: 'two boxes',
        barcodes: const <String>[
          '09501101530003',
          '09504000059118',
        ],
      ));

      expect(window.startedNewPack, isFalse);
      expect(window.frames, hasLength(2));
    });
  });

  group('information-gain scan guidance', () {
    test('many missing identity dimensions prefer one machine-code observation', () {
      final guidance = nextBestMedicineScanGuidance(
        _draft(
          name: '',
          brand: '',
          salt: '',
          strength: '',
          form: '',
          expiry: '',
          overall: .35,
        ),
        captureAttempts: 1,
      );

      expect(guidance.focus, MedicineScanFocus.machineCode);
      expect(guidance.readyForAutomaticHandoff, isFalse);
      expect(guidance.message, contains('DataMatrix'));
    });

    test('composition remains best when brand is known but dose pair is missing', () {
      final guidance = nextBestMedicineScanGuidance(
        _draft(salt: '', strength: ''),
        captureAttempts: 1,
      );

      expect(guidance.focus, MedicineScanFocus.composition);
    });

    test('conflicted trusted barcode never reports ready', () {
      final guidance = nextBestMedicineScanGuidance(
        _draft(
          barcode: '09504000059118',
          barcodeConflicted: true,
        ),
        captureAttempts: 1,
      );

      expect(guidance.focus, MedicineScanFocus.machineCode);
      expect(guidance.readyForAutomaticHandoff, isFalse);
      expect(guidance.message, contains('More than one'));
    });

    test('multi-product camera frame never auto-handoffs even after recapture budget', () {
      final guidance = nextBestMedicineScanGuidance(
        _draft(barcode: '09504000059118'),
        captureAttempts: 2,
        ambiguousMachineCodes: true,
      );

      expect(guidance.focus, MedicineScanFocus.machineCode);
      expect(guidance.readyForAutomaticHandoff, isFalse);
      expect(guidance.message, contains('one pack'));
    });
  });
}
