import 'medicine_scan_commit.dart';
import 'medicine_understanding.dart';
import 'regulatory_medicine_code.dart';

enum MedicineScanFocus {
  ready,
  imageQuality,
  frontIdentity,
  composition,
  strength,
  dosageForm,
  machineCode,
  lotDetails,
  review,
}

/// A small active-perception decision: either hand the evidence to review or
/// request the single next view most likely to remove uncertainty.
///
/// This never authorizes persistence. Existing review/commit gates remain the
/// only stock-writing authority.
class MedicineScanGuidance {
  const MedicineScanGuidance({
    required this.focus,
    required this.message,
    required this.readyForAutomaticHandoff,
  });

  final MedicineScanFocus focus;
  final String message;
  final bool readyForAutomaticHandoff;
}

MedicineScanGuidance nextBestMedicineScanGuidance(
  MedicineScanDraft? draft, {
  double evidenceQuality = .65,
  String physicalGuidance = '',
  int captureAttempts = 0,
}) {
  final quality = evidenceQuality.isFinite
      ? evidenceQuality.clamp(0.0, 1.0).toDouble()
      : .65;
  final physical = physicalGuidance.trim();

  if (draft == null) {
    return MedicineScanGuidance(
      focus: physical.isNotEmpty
          ? MedicineScanFocus.imageQuality
          : MedicineScanFocus.frontIdentity,
      message: physical.isNotEmpty
          ? physical
          : 'Show the medicine name or barcode clearly.',
      readyForAutomaticHandoff: false,
    );
  }

  // A checksum-valid GTIN or structured GS1 carrier is strong enough to move
  // into the review pipeline, where local/master identity knowledge can resolve
  // the product. It is never proof of authenticity and never bypasses review.
  if (_trustedMachineReadableIdentity(draft.barcode)) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.ready,
      message: 'Medicine code captured. Ready to review.',
      readyForAutomaticHandoff: true,
    );
  }

  // Physical readability problems outrank semantic requests on the first try:
  // asking for a composition side while the frame is blurred/glared is not useful.
  if ((physical.isNotEmpty && quality < .58) || quality < .30) {
    if (captureAttempts >= 2) {
      return const MedicineScanGuidance(
        focus: MedicineScanFocus.review,
        message: 'Some details are still unclear. Continue and confirm them in review.',
        readyForAutomaticHandoff: true,
      );
    }
    return MedicineScanGuidance(
      focus: MedicineScanFocus.imageQuality,
      message: physical.isNotEmpty
          ? physical
          : 'Move closer, hold steady and use even light.',
      readyForAutomaticHandoff: false,
    );
  }

  final brand = draft.field('brand');
  final name = draft.field('name');
  final salt = draft.field('salt');
  final strength = draft.field('strength');
  final form = draft.field('form');
  final expiry = draft.field('expiry');

  bool weak(ExtractedMedicineField field, {double minimum = .78}) =>
      field.value.trim().isEmpty ||
      field.conflicted ||
      field.confidence < minimum;

  MedicineScanGuidance ask(MedicineScanFocus focus, String message) {
    // Two deliberate still captures are a bounded acquisition budget. After
    // that, move to the existing fail-closed review instead of trapping the user
    // in an endless scanning loop or guessing a missing medicine fact.
    if (captureAttempts >= 2) {
      return const MedicineScanGuidance(
        focus: MedicineScanFocus.review,
        message: 'Some details still need checking. Continue to review.',
        readyForAutomaticHandoff: true,
      );
    }
    return MedicineScanGuidance(
      focus: focus,
      message: message,
      readyForAutomaticHandoff: false,
    );
  }

  if (weak(brand) && weak(name)) {
    return ask(
      MedicineScanFocus.frontIdentity,
      'Show the front with the medicine name clearly.',
    );
  }
  if (weak(salt)) {
    return ask(
      MedicineScanFocus.composition,
      salt.conflicted
          ? 'Show the composition/salt side clearly to resolve the conflict.'
          : 'Show the composition or salt side.',
    );
  }
  if (weak(strength)) {
    return ask(
      MedicineScanFocus.strength,
      strength.conflicted
          ? 'Show the printed strength (mg/ml) clearly to resolve the conflict.'
          : 'Show the printed strength (mg/ml) clearly.',
    );
  }
  if (weak(form) || confirmedScanForm(draft).isEmpty) {
    return ask(
      MedicineScanFocus.dosageForm,
      'Show where Tablet, Capsule, Syrup or the dosage form is printed.',
    );
  }

  final identityIssue = scanQuickIdentityIssue(draft);
  if (identityIssue.isNotEmpty) {
    return ask(
      MedicineScanFocus.machineCode,
      'Show the barcode/QR/DataMatrix, or another clear identity side.',
    );
  }

  // Expiry is not required to identify a product, but it is high-value pharmacy
  // stock evidence. Spend at most one extra still trying to capture it; review
  // remains available immediately through the existing Use scan action.
  if (weak(expiry) && captureAttempts < 2) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.lotDetails,
      message: 'For better stock tracking, show the Batch + EXP side.',
      readyForAutomaticHandoff: false,
    );
  }

  return const MedicineScanGuidance(
    focus: MedicineScanFocus.ready,
    message: 'Medicine details are clear. Ready to review.',
    readyForAutomaticHandoff: true,
  );
}

bool _trustedMachineReadableIdentity(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return false;
  final structured = parseRegulatoryMedicineCode(value);
  if (structured?.hasVerifiedProductIdentifier == true) return true;

  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits != value || !const {8, 12, 13, 14}.contains(digits.length)) {
    return false;
  }
  var sum = 0;
  for (
    var index = digits.length - 2, position = 1;
    index >= 0;
    index--, position++
  ) {
    sum += int.parse(digits[index]) * (position.isOdd ? 3 : 1);
  }
  return (10 - sum % 10) % 10 == int.parse(digits[digits.length - 1]);
}
