import '../lib/domain/medicine_understanding.dart';

Map<String, void Function()> medicineUnderstandingContract() => {
  'extracts labelled medicine facts without inventing stock values': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        timestampMs: 0,
        quality: .94,
        barcode: '8901234567890',
        text: '''
DOLO 650
Paracetamol Tablets IP 650 mg
B.No. DL2407
MFG 08/2026 EXP 07/2028
10 x 15 Tablets
MRP Rs. 35.00 incl. of all taxes
Manufactured by Micro Labs Limited
''',
      ),
    ]);
    _equal(result.drafts.length, 1);
    final draft = result.drafts.single;
    _equal(draft.name, 'Dolo');
    _equal(draft.brand, 'Dolo');
    _equal(draft.salt, 'Paracetamol');
    _equal(draft.strength.toLowerCase(), '650 mg');
    _equal(draft.form, 'Tablet');
    _equal(draft.mfg, '2026-08');
    _equal(draft.expiry, '2028-07');
    _equal(draft.batchNumber, 'DL2407');
    _equal(draft.barcode, '8901234567890');
    _equal(draft.printedPackSize.toLowerCase(), '10 x 15 tablets');
    _equal(draft.printedMrp, '₹35.00');
    _check(!draft.fields.containsKey('quantity'), 'pack size became quantity');
    _check(
      !draft.fields.containsKey('unitPricePaise'),
      'MRP became stock cost',
    );
  },
  'splits a sequential video into separate medicine drafts': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        timestampMs: 0,
        text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
      ),
      const MedicineFrameEvidence(
        sequence: 1,
        timestampMs: 900,
        text: 'B.No D11\nMFG 08/2026 EXP 07/2028',
      ),
      const MedicineFrameEvidence(
        sequence: 2,
        timestampMs: 1800,
        text: 'AZITHRAL 500\nAzithromycin Tablets IP 500 mg',
      ),
      const MedicineFrameEvidence(
        sequence: 3,
        timestampMs: 2700,
        text: 'Batch AZ442\nMFG 06/2026 EXP 05/2028',
      ),
      const MedicineFrameEvidence(
        sequence: 4,
        timestampMs: 3600,
        text: 'CROCIN ADVANCE\nParacetamol Tablets IP 500 mg',
      ),
    ]);
    _equal(result.drafts.length, 3);
    _equal(result.drafts[0].name, 'Dolo');
    _equal(result.drafts[0].batchNumber, 'D11');
    _equal(result.drafts[1].name, 'Azithral');
    _equal(result.drafts[1].batchNumber, 'AZ442');
    _equal(result.drafts[2].name, 'Crocin Advance');
  },
  'merges complementary views of the same pack': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        barcode: '1112223334445',
        text: 'MONTEK LC\nTablets',
      ),
      const MedicineFrameEvidence(
        sequence: 1,
        barcode: '1112223334445',
        text: 'Composition\nMontelukast Sodium 10 mg + Levocetirizine 5 mg',
      ),
      const MedicineFrameEvidence(
        sequence: 2,
        barcode: '1112223334445',
        text: 'MFG 07/2026\nEXP 06/2028\nBatch ML88',
      ),
    ]);
    _equal(result.drafts.length, 1);
    final draft = result.drafts.single;
    _equal(draft.name, 'Montek LC');
    _check(
      draft.salt.toLowerCase().contains('montelukast'),
      'first salt missing',
    );
    _check(
      draft.salt.toLowerCase().contains('levocetirizine'),
      'second salt missing',
    );
    _check(draft.strength.contains('10 mg'), 'first strength missing');
    _check(draft.strength.contains('5 mg'), 'second strength missing');
    _equal(draft.batchNumber, 'ML88');
  },
  'different strength creates a new medicine boundary': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        text: 'WARF 2.5\nWarfarin Sodium Tablets IP 2.5 mg',
      ),
      const MedicineFrameEvidence(
        sequence: 1,
        text: 'WARF 25\nWarfarin Sodium Tablets IP 25 mg',
      ),
    ]);
    _equal(result.drafts.length, 2);
    _equal(result.drafts[0].strength.toLowerCase(), '2.5 mg');
    _equal(result.drafts[1].strength.toLowerCase(), '25 mg');
  },
  'deduplicates repeated adjacent OCR frames and keeps clearer evidence': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        quality: .35,
        text: 'CEFIX 200\nCefixime Tablets IP 200 mg',
      ),
      const MedicineFrameEvidence(
        sequence: 1,
        quality: .95,
        text: 'CEFIX 200\nCefixime Tablets IP 200 mg',
      ),
    ]);
    _equal(result.drafts.length, 1);
    _equal(result.ignoredFrames, 1);
    _equal(result.drafts.single.frameSequences.single, 1);
  },
  'duplicate fusion keeps complementary barcode and labelled facts': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        quality: .96,
        text: 'CEFIX 200\nCefixime Tablets IP 200 mg',
      ),
      const MedicineFrameEvidence(
        sequence: 1,
        quality: .42,
        barcode: '8901234567890',
        text: 'CEFIX 200\nCefixime Tablets IP 200 mg\nEXP 08/2028',
      ),
    ]);
    _equal(result.drafts.length, 1);
    _equal(result.ignoredFrames, 1);
    _equal(result.drafts.single.barcode, '8901234567890');
    _equal(result.drafts.single.expiry, '2028-08');
  },
  'same product barcode with a different batch stays separate stock': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        quality: 1,
        barcode: '8901234567890',
        text: 'CEFIX 200\nCefixime Tablets IP 200 mg\nBatch CF100\nEXP 08/2028',
      ),
      const MedicineFrameEvidence(
        sequence: 1,
        quality: 1,
        barcode: '8901234567890',
        text: 'CEFIX 200\nCefixime Tablets IP 200 mg\nBatch ZX900\nEXP 11/2028',
      ),
    ]);
    _equal(result.drafts.length, 2);
    _equal(result.drafts[0].batchNumber, 'CF100');
    _equal(result.drafts[1].batchNumber, 'ZX900');
  },
  'explicit local list rows become separate review drafts': () {
    final evidence = medicineListEvidence(
      '1. DOLO 650 mg\n2. DOLO 500 mg\n3. AZITHRAL 500 mg',
      source: 'Clipboard',
    );
    _equal(evidence.length, 3);
    final result = const MedicineUnderstandingEngine().understand(evidence);
    _equal(result.drafts.length, 3);
    _equal(result.drafts[0].name, 'Dolo');
    _equal(result.drafts[0].strength.toLowerCase(), '650 mg');
    _equal(result.drafts[1].strength.toLowerCase(), '500 mg');
    _equal(result.drafts[2].name, 'Azithral');
  },
  'oversized local list is rejected instead of silently truncated': () {
    var rejected = false;
    try {
      medicineListEvidence(
        List.generate(241, (index) => 'Medicine $index').join('\n'),
        source: 'Imported text file',
      );
    } on FormatException {
      rejected = true;
    }
    _check(rejected, 'Oversized list was silently accepted.');
  },
  'keeps MFG and expiry roles separate and rejects reversed chronology': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        text: 'TESTMED\nMFG 09/2028\nEXP 08/2027',
      ),
    ]);
    final draft = result.drafts.single;
    _equal(draft.expiry, '2027-08');
    _equal(draft.mfg, '');
  },
  'message roundtrip preserves isolate-safe evidence and drafts': () {
    const frame = MedicineFrameEvidence(
      barcode: '123456',
      barcodes: ['123456', '999999'],
      text: 'CALPOL\nParacetamol 250 mg',
      source: 'frame 1',
      sequence: 4,
      timestampMs: 2200,
      quality: .8,
    );
    final decoded = MedicineFrameEvidence.fromMessage(frame.toMessage());
    _equal(decoded.sequence, 4);
    _equal(decoded.timestampMs, 2200);
    _equal(decoded.allBarcodes.length, 2);
    final output = understandMedicineEvidenceMessage({
      'evidence': [frame.toMessage()],
    });
    final result = MedicineUnderstandingResult.fromMessage(output);
    _equal(result.drafts.length, 1);
    _equal(result.drafts.single.name, 'Calpol');
  },
};

void _equal(Object? actual, Object? expected) {
  if (actual != expected)
    throw StateError('Expected <$expected>, got <$actual>.');
}

void _check(bool value, String message) {
  if (!value) throw StateError(message);
}
