import '../lib/domain/medicine.dart';
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
  'ignores marketing headers and follows split composition and date labels':
      () {
        final result = const MedicineUnderstandingEngine().understand([
          const MedicineFrameEvidence(
            sequence: 0,
            quality: .92,
            text: '''
NEW IMPROVED FORMULA
DOLO 650
COMPOSITION
Each uncoated tablet contains
Paracetamol I.P.
650 mg
Excipients q.s.
MFG DATE
08/2026
EXP DATE
07/2028
''',
          ),
        ]);
        final draft = result.drafts.single;
        _equal(draft.name, 'Dolo');
        _equal(draft.salt, 'Paracetamol');
        _equal(draft.strength.toLowerCase(), '650 mg');
        _equal(draft.mfg, '2026-08');
        _equal(draft.expiry, '2028-07');
      },
  'keeps multi-line combination salts inside one composition scope': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        quality: .95,
        text: '''
MONTEK LC
COMPOSITION:
Montelukast Sodium I.P. 10 mg +
Levocetirizine Hydrochloride I.P.
5 mg
Excipients q.s.
''',
      ),
    ]);
    final draft = result.drafts.single;
    _equal(draft.name, 'Montek LC');
    _check(
      draft.salt.toLowerCase().contains('montelukast sodium'),
      'first composition ingredient was lost',
    );
    _check(
      draft.salt.toLowerCase().contains('levocetirizine hydrochloride'),
      'second composition ingredient was lost',
    );
    _check(!draft.salt.toLowerCase().contains('i p'), 'I.P. became a salt');
    _check(draft.strength.contains('10 mg'), 'first strength missing');
    _check(draft.strength.contains('5 mg'), 'second strength missing');
  },
  'links month-name dates placed below their field labels': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        text: 'TESTMED\nMFD\nAUG 2026\nUSE BEFORE\nJUL 2028',
      ),
    ]);
    final draft = result.drafts.single;
    _equal(draft.mfg, '2026-08');
    _equal(draft.expiry, '2028-07');
  },
  'canonicalizes OCR-confused active ingredients inside composition': () {
    final result = const MedicineUnderstandingEngine().understand([
      const MedicineFrameEvidence(
        sequence: 0,
        quality: .91,
        text: '''
TEST 500
COMPOSITION
PARACETAM0L I.P. 500 mg
''',
      ),
    ]);
    _equal(result.drafts.single.salt, 'Paracetamol');
    _equal(result.drafts.single.strength.toLowerCase(), '500 mg');
  },
  'uses a local product signature to repair brand and strength OCR': () {
    final result =
        const MedicineUnderstandingEngine(
          knowledge: <MedicineKnowledgeEntry>[
            MedicineKnowledgeEntry(
              name: 'Dolo',
              brand: 'Dolo',
              salt: 'Paracetamol',
              strength: '650 mg',
              form: 'Tablet',
            ),
          ],
        ).understand([
          const MedicineFrameEvidence(
            sequence: 0,
            quality: .88,
            text: 'D0L0 6SO\nTABLETS',
          ),
        ]);
    final draft = result.drafts.single;
    _equal(draft.name, 'Dolo');
    _equal(draft.brand, 'Dolo');
    _equal(draft.strength.toLowerCase(), '650 mg');
  },
  'fills only unambiguous identity facts from a verified local barcode': () {
    final result =
        const MedicineUnderstandingEngine(
          knowledge: <MedicineKnowledgeEntry>[
            MedicineKnowledgeEntry(
              name: 'Calpol',
              brand: 'Calpol',
              salt: 'Paracetamol',
              strength: '250 mg/5 ml',
              form: 'Syrup',
              manufacturer: 'GlaxoSmithKline',
              barcode: '8901234567001',
            ),
          ],
        ).understand([
          const MedicineFrameEvidence(
            sequence: 0,
            barcode: '8901234567001',
            text: 'blurred unreadable label',
          ),
        ]);
    final draft = result.drafts.single;
    _equal(draft.name, 'Calpol');
    _equal(draft.salt, 'Paracetamol');
    _equal(draft.strength, '250 mg/5 ml');
    _equal(draft.form, 'Syrup');
    _check(!draft.fields.containsKey('quantity'), 'barcode invented quantity');
    _check(!draft.fields.containsKey('expiry'), 'barcode invented expiry');
  },
  'refuses conflicting local identities that share one barcode': () {
    final result =
        const MedicineUnderstandingEngine(
          knowledge: <MedicineKnowledgeEntry>[
            MedicineKnowledgeEntry(name: 'Alpha', barcode: '99887766'),
            MedicineKnowledgeEntry(name: 'Beta', barcode: '99887766'),
          ],
        ).understand([
          const MedicineFrameEvidence(sequence: 0, barcode: '99887766'),
        ]);
    _equal(result.drafts.single.name, '');
    _equal(result.drafts.single.barcode, '99887766');
  },
  'builds bounded identity memory only from active local records': () {
    final knowledge = medicineKnowledgeFromRecords(<Medicine>[
      Medicine(id: 'active', name: 'Dolo', salt: 'Paracetamol'),
      Medicine(id: 'archived', name: 'Old Drug', archived: true),
    ]);
    _equal(knowledge.length, 1);
    _equal(knowledge.single.name, 'Dolo');
    _check(
      !knowledge.single.toMessage().containsKey('quantity'),
      'knowledge leaked stock data',
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
      'knowledge': const [
        MedicineKnowledgeEntry(
          name: 'Calpol',
          brand: 'Calpol',
          salt: 'Paracetamol',
        ),
      ].map((entry) => entry.toMessage()).toList(),
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
