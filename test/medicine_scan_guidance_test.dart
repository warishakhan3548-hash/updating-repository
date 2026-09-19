import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_scan_guidance.dart';
import '../lib/domain/medicine_understanding.dart';

ExtractedMedicineField _field(String value, {double confidence = .92}) =>
    ExtractedMedicineField(value: value, confidence: confidence, support: 1);

MedicineScanDraft _draft({
  String brand = 'Dolo',
  String salt = 'Paracetamol',
  String strength = '650 mg',
  String form = 'Tablet',
  String expiry = '2027-10',
  String batch = '',
  String barcode = '',
  double overall = .91,
}) => MedicineScanDraft(
  fields: {
    if (brand.isNotEmpty) 'brand': _field(brand),
    if (salt.isNotEmpty) 'salt': _field(salt),
    if (strength.isNotEmpty) 'strength': _field(strength),
    if (form.isNotEmpty) 'form': _field(form),
    if (expiry.isNotEmpty) 'expiry': _field(expiry),
    if (batch.isNotEmpty) 'batchNumber': _field(batch),
    if (barcode.isNotEmpty) 'barcode': _field(barcode),
  },
  rawText: '$brand\n$salt $strength\n$form\nEXP $expiry\nBATCH $batch',
  searchKeywords: '',
  frameSequences: const [0],
  expiryMonthOnly: expiry.length == 7,
  overallConfidence: overall,
);

MedicineFrameEvidence _frame(
  String barcode, {
  int sequence = 0,
  String text = 'medicine pack',
  double quality = .8,
}) => MedicineFrameEvidence(
  text: text,
  barcode: barcode,
  sequence: sequence,
  quality: quality,
);

void main() {
  test('complete medicine can hand off automatically', () {
    final guidance = nextBestMedicineScanGuidance(
      _draft(),
      captureAttempts: 1,
    );
    expect(guidance.readyForAutomaticHandoff, isTrue);
    expect(guidance.focus, MedicineScanFocus.ready);
  });

  test('missing salt asks for composition instead of guessing', () {
    final guidance = nextBestMedicineScanGuidance(
      _draft(salt: ''),
      captureAttempts: 1,
    );
    expect(guidance.readyForAutomaticHandoff, isFalse);
    expect(guidance.focus, MedicineScanFocus.composition);
  });

  test('expiry gets one bounded extra capture opportunity', () {
    final first = nextBestMedicineScanGuidance(
      _draft(expiry: ''),
      captureAttempts: 1,
    );
    expect(first.focus, MedicineScanFocus.lotDetails);
    expect(first.readyForAutomaticHandoff, isFalse);

    final second = nextBestMedicineScanGuidance(
      _draft(expiry: ''),
      captureAttempts: 2,
    );
    expect(second.readyForAutomaticHandoff, isTrue);
  });

  test('poor image quality is fixed before asking semantic questions', () {
    final guidance = nextBestMedicineScanGuidance(
      _draft(salt: ''),
      evidenceQuality: .22,
      physicalGuidance: 'Move closer and hold steady.',
      captureAttempts: 0,
    );
    expect(guidance.focus, MedicineScanFocus.imageQuality);
    expect(guidance.message, contains('Move closer'));
  });

  test('identity-only GTIN asks once for physical lot evidence', () {
    final first = nextBestMedicineScanGuidance(
      _draft(
        brand: '',
        salt: '',
        strength: '',
        form: '',
        expiry: '',
        barcode: '09504000059118',
        overall: .4,
      ),
      captureAttempts: 1,
    );
    expect(first.readyForAutomaticHandoff, isFalse);
    expect(first.focus, MedicineScanFocus.lotDetails);
    expect(first.message, contains('Batch'));

    final second = nextBestMedicineScanGuidance(
      _draft(
        brand: '',
        salt: '',
        strength: '',
        form: '',
        expiry: '',
        barcode: '09504000059118',
        overall: .4,
      ),
      captureAttempts: 2,
    );
    expect(second.readyForAutomaticHandoff, isTrue);
    expect(second.focus, MedicineScanFocus.ready);
  });

  test('GTIN plus trusted batch and expiry can hand off immediately', () {
    final guidance = nextBestMedicineScanGuidance(
      _draft(
        brand: '',
        salt: '',
        strength: '',
        form: '',
        expiry: '2027-10',
        batch: 'LOT7',
        barcode: '09504000059118',
        overall: .4,
      ),
      captureAttempts: 1,
    );
    expect(guidance.readyForAutomaticHandoff, isTrue);
    expect(guidance.focus, MedicineScanFocus.ready);
  });

  test('different trusted GTIN starts a fresh single-pack window', () {
    final window = mergeSinglePackMedicineEvidence(
      [_frame('09504000059118', sequence: 1)],
      _frame('09501101530003', sequence: 2),
    );
    expect(window.startedNewPack, isTrue);
    expect(window.evidenceChanged, isTrue);
    expect(window.frames, hasLength(1));
    expect(window.frames.single.barcode, '09501101530003');
  });

  test('same GTIN with a different explicit lot starts a fresh window', () {
    final window = mergeSinglePackMedicineEvidence(
      [
        _frame(
          '(01)09504000059118(17)271031(10)LOT7',
          sequence: 1,
        ),
      ],
      _frame(
        '(01)09504000059118(17)271031(10)LOT8',
        sequence: 2,
      ),
    );
    expect(window.startedNewPack, isTrue);
    expect(window.frames, hasLength(1));
  });

  test('same GTIN and lot keeps complementary evidence', () {
    final window = mergeSinglePackMedicineEvidence(
      [
        _frame(
          '(01)09504000059118(17)271031(10)LOT7',
          sequence: 1,
          text: 'front name',
        ),
      ],
      _frame(
        '(01)09504000059118(17)271031(10)LOT7',
        sequence: 2,
        text: 'composition side',
      ),
    );
    expect(window.startedNewPack, isFalse);
    expect(window.frames, hasLength(2));
  });

  test('untrusted barcode noise cannot force a pack reset', () {
    final window = mergeSinglePackMedicineEvidence(
      [_frame('09504000059118', sequence: 1)],
      _frame('PROMO-QR-NOT-GTIN', sequence: 2),
    );
    expect(window.startedNewPack, isFalse);
    expect(window.evidenceChanged, isTrue);
    expect(window.frames, hasLength(2));
  });

  test('inferior exact duplicate leaves the accepted evidence unchanged', () {
    final window = mergeSinglePackMedicineEvidence(
      [
        _frame(
          '09504000059118',
          sequence: 1,
          text: 'Dolo 650 mg',
          quality: .92,
        ),
      ],
      _frame(
        '09504000059118',
        sequence: 2,
        text: 'Dolo 650 mg',
        quality: .42,
      ),
    );

    expect(window.startedNewPack, isFalse);
    expect(window.evidenceChanged, isFalse);
    expect(window.frames, hasLength(1));
    expect(window.frames.single.sequence, 1);
  });

  test('better exact duplicate replaces the old accepted observation', () {
    final window = mergeSinglePackMedicineEvidence(
      [
        _frame(
          '09504000059118',
          sequence: 1,
          text: 'Dolo 650 mg',
          quality: .42,
        ),
      ],
      _frame(
        '09504000059118',
        sequence: 2,
        text: 'Dolo 650 mg',
        quality: .92,
      ),
    );

    expect(window.startedNewPack, isFalse);
    expect(window.evidenceChanged, isTrue);
    expect(window.frames, hasLength(1));
    expect(window.frames.single.sequence, 2);
  });
}
