import '../lib/domain/medicine_intake.dart';
import '../lib/domain/medicine_resolution_v2.dart';
import '../lib/domain/medicine_understanding.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

MedicineUnderstandingResult _understand(List<MedicineFrameEvidence> frames) =>
    MedicineUnderstandingResult.fromMessage(
      understandMedicineEvidenceV2Message({
        'evidence': frames.map((frame) => frame.toMessage()).toList(),
      }),
    );

List<MedicineFrameEvidence> _frames(List<String> text) => [
  for (var i = 0; i < text.length; i++)
    MedicineFrameEvidence(
      text: text[i],
      sequence: i,
      timestampMs: i * 800,
      quality: .8,
    ),
];

Map<String, void Function()> videoMedicineContract() => {
  'similar product names with different ingredients are separate packs': () {
    final result = _understand(
      _frames([
        'ALPHA COLD\nComposition: Paracetamol IP 500 mg',
        'ALPHA GOLD\nComposition: Metformin IP 500 mg',
      ]),
    );
    _check(result.drafts.length == 2, 'Two distinct salts were fused');
    _check(
      !result.drafts.first.rawText.contains('Metformin'),
      'Second pack leaked into first',
    );
    _check(
      !result.drafts.last.rawText.contains('Paracetamol'),
      'First pack leaked into second',
    );
  },
  'explicit similar trade names cannot fuzzy-deduplicate': () {
    final result = _understand(
      _frames([
        'Brand name: CETRIZ\nCetirizine Tablets IP 10 mg',
        'Brand name: CETRIM\nCetirizine Tablets IP 10 mg',
      ]),
    );
    _check(result.drafts.length == 2, 'Explicit distinct brands merged');
  },
  'front identity survives more than four back-panel views': () {
    final result = _understand(
      _frames([
        'DOLO 650\nParacetamol Tablets IP 650 mg',
        'MFG 01/2026',
        'EXP 02/2028',
        'Batch D100',
        'MRP Rs 30',
        'Manufactured by Test Pharma Ltd',
        'AZITHRAL 500\nAzithromycin Tablets IP 500 mg',
      ]),
    );
    _check(result.drafts.length == 2, 'Front identity was forgotten');
    _check(result.drafts.first.batchNumber == 'D100', 'First lot lost');
    _check(
      result.drafts.last.batchNumber.isEmpty &&
          result.drafts.last.expiry.isEmpty,
      'Second medicine inherited the first lot/date',
    );
  },
  'different lot on an unnamed back remains a separate review draft': () {
    final result = _understand(
      _frames([
        'CEFIX 200\nCefixime Tablets IP 200 mg\nBatch CF100\nEXP 08/2028',
        'Batch ZX900\nEXP 11/2028',
      ]),
    );
    _check(result.drafts.length == 2, 'Explicit lot boundary was erased');
    _check(result.drafts.last.name.isEmpty, 'Unknown back borrowed a name');
    _check(result.drafts.last.batchNumber == 'ZX900', 'New lot was lost');
  },
  'one-digit batch differences cannot silently collapse': () {
    final result = _understand(
      _frames([
        'CEFIX\nBatch CF100\nEXP 08/2028',
        'CEFIX\nBatch CF101\nEXP 08/2028',
      ]),
    );
    _check(result.drafts.length == 2, 'Distinct numbered lots were merged');
  },
  'different barcodes still split equal-name packs': () {
    final result = _understand([
      const MedicineFrameEvidence(
        text: 'CEFIX',
        barcode: '11111111',
        sequence: 0,
      ),
      const MedicineFrameEvidence(
        text: 'CEFIX',
        barcode: '22222222',
        sequence: 1,
      ),
    ]);
    _check(result.drafts.length == 2, 'Name overrode a different barcode');
  },
  'same product complementary panels remain together': () {
    final result = _understand(
      _frames([
        'Brand name: MONTEK LC\nTablets',
        'Composition\nMontelukast Sodium 10 mg + Levocetirizine 5 mg',
        'MFG 07/2026',
        'EXP 06/2028',
        'Batch ML88',
      ]),
    );
    _check(result.drafts.length == 1, 'One pack was unnecessarily split');
    _check(
      result.drafts.single.salt.toLowerCase().contains('montelukast'),
      'Composition lost',
    );
    _check(result.drafts.single.batchNumber == 'ML88', 'Back lost');
  },
  'partial combination view does not become another medicine': () {
    final result = _understand(
      _frames([
        'MONTEK LC\nComposition: Montelukast Sodium + Levocetirizine',
        'MONTEK LC\nComposition: Levocetirizine',
      ]),
    );
    _check(result.drafts.length == 1, 'Partial ingredient list split a pack');
  },
  'month and full-day expiry in that month remain one pack': () {
    final result = _understand(
      _frames(['CEFIX 200\nEXP 08/2028', 'CEFIX 200\nEXP 31/08/2028']),
    );
    _check(
      result.drafts.length == 1,
      'Compatible date precision split the pack',
    );
  },
  'weak explicit row boundary must not be repaired away': () {
    final result = _understand([
      const MedicineFrameEvidence(text: 'CEFIX 200', sequence: 0),
      const MedicineFrameEvidence(
        text: 'EXP 09/2028',
        sequence: 1,
        startsNewItem: true,
      ),
    ]);
    _check(result.drafts.length == 2, 'Explicit boundary erased');
    _check(
      result.drafts.first.expiry.isEmpty,
      'Unassigned date contaminated first item',
    );
  },
  'completed pack is never replayed from the transition tail': () {
    final frames = _frames([
      'DOLO 650\nParacetamol Tablets IP 650 mg',
      'DOLO 650\nParacetamol Tablets IP 650 mg',
      'AZITHRAL 500\nAzithromycin Tablets IP 500 mg',
    ]);
    final first = finishMedicineVideoWindow(
      frames,
      _understand(frames).drafts,
      isLast: false,
    );
    final second = finishMedicineVideoWindow(
      first.carry,
      _understand(first.carry).drafts,
      isLast: true,
    );
    _check(
      first.completed.length + second.completed.length == 2,
      'Completed medicine replayed',
    );
    final emitted = first.completed.expand((d) => d.frameSequences).toSet();
    _check(
      first.carry.every((f) => !emitted.contains(f.sequence)),
      'Emitted frames still in carry',
    );
  },
  'three-minute multi-pack video yields every pack exactly once': () {
    final names = [
      'NOVAALPHA',
      'NOVABETA',
      'NOVAGAMMA',
      'NOVADELT',
      'NOVAOMEGA',
      'NOVAZETA',
    ];
    var carry = <MedicineFrameEvidence>[];
    final completed = <MedicineScanDraft>[];
    for (var start = 0; start < 180000; start += 20000) {
      final frames = [
        ...carry,
        for (var time = start; time < start + 20000; time += 500)
          MedicineFrameEvidence(
            sequence: time,
            timestampMs: time,
            quality: .8,
            text:
                'Brand name: ${names[(time ~/ 10000) % names.length]}\n'
                'Composition: Paracetamol IP 500 mg\nBatch LOT${100 + time ~/ 10000}',
          ),
      ];
      final window = finishMedicineVideoWindow(
        frames,
        _understand(frames).drafts,
        isLast: start == 160000,
      );
      completed.addAll(window.completed);
      carry = window.carry;
      _check(carry.length <= 48, 'Unbounded video memory');
    }
    _check(completed.length == 18, 'Expected 18 lots, got ${completed.length}');
    _check(
      completed.map((d) => d.batchNumber).toSet().length == 18,
      'Lot lost or duplicated',
    );
  },
  'carry retains a unique middle panel during a slow long pan': () {
    final frames = [
      for (var i = 0; i < 100; i++)
        MedicineFrameEvidence(
          sequence: i,
          timestampMs: i * 500,
          text: i == 50 ? 'EXP 09/2029\nBatch MID555' : 'CEFIX 200',
        ),
    ];
    final draft = MedicineScanDraft(
      fields: const {},
      rawText: 'CEFIX 200',
      searchKeywords: '',
      frameSequences: frames.map((f) => f.sequence).toList(),
    );
    final result = finishMedicineVideoWindow(frames, [draft], isLast: false);
    _check(result.carry.length == 48, 'Carry cap changed');
    _check(
      result.carry.any((f) => f.sequence == 50),
      'Unique middle date/lot lost',
    );
    _check(
      result.carry.first.sequence == 0 && result.carry.last.sequence == 99,
      'Anchor/tail lost',
    );
  },
  'coverage count survives persistence and old checkpoints still load': () {
    final job = MedicineIntakeJob(
      id: 'a' * 32,
      kind: 'video',
      title: 'clip',
      path: '/private/clip.mp4',
      status: 'review',
      cursorMs: 180000,
      durationMs: 180000,
      unreadableFrames: 7,
    );
    final restored = MedicineIntakeJob.fromJson(job.toJson());
    _check(
      restored.unreadableFrames == 7 && restored.canRescanVideo,
      'Coverage/rescan was not durable',
    );
    final old = job.toJson()..remove('unreadableFrames');
    _check(
      MedicineIntakeJob.fromJson(old).unreadableFrames == 0,
      'Old schema stopped loading',
    );
  },
  'completed source-free video never advertises rescan': () {
    final job = MedicineIntakeJob(
      id: 'b' * 32,
      kind: 'video',
      title: 'clip',
      status: 'review',
      cursorMs: 20000,
      durationMs: 20000,
      unreadableFrames: 3,
    );
    _check(!job.canRescanVideo, 'Deleted source advertised as available');
  },
};
