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
  String barcode = '',
  double overall = .91,
}) => MedicineScanDraft(
  fields: {
    if (brand.isNotEmpty) 'brand': _field(brand),
    if (salt.isNotEmpty) 'salt': _field(salt),
    if (strength.isNotEmpty) 'strength': _field(strength),
    if (form.isNotEmpty) 'form': _field(form),
    if (expiry.isNotEmpty) 'expiry': _field(expiry),
    if (barcode.isNotEmpty) 'barcode': _field(barcode),
  },
  rawText: '$brand\n$salt $strength\n$form\nEXP $expiry',
  searchKeywords: '',
  frameSequences: const [0],
  expiryMonthOnly: expiry.length == 7,
  overallConfidence: overall,
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

  test('verified GTIN can move to review without invented OCR identity', () {
    final guidance = nextBestMedicineScanGuidance(
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
    expect(guidance.readyForAutomaticHandoff, isTrue);
    expect(guidance.focus, MedicineScanFocus.ready);
  });
}
