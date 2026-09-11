import 'intake_resolution.dart';
import 'medicine.dart';
import 'medicine_understanding.dart';

/// Final, deterministic gate between a scan preview and a one-tap inventory add.
///
/// AI/OCR may propose identity facts, but only the human-visible preview can
/// authorize creation. Existing-stock ambiguity, weak lot identity and invalid
/// chronology remain fail-closed. The controller's revision/CAS boundary is the
/// final authority at commit time.
class ScanQuickAddDecision {
  const ScanQuickAddDecision._({
    required this.allowed,
    required this.isNewBatch,
    required this.reason,
  });

  const ScanQuickAddDecision.allowed({bool isNewBatch = false})
      : this._(allowed: true, isNewBatch: isNewBatch, reason: '');

  const ScanQuickAddDecision.blocked(String reason)
      : this._(allowed: false, isNewBatch: false, reason: reason);

  final bool allowed;
  final bool isNewBatch;
  final String reason;

  String get actionLabel =>
      isNewBatch ? 'Confirm & add new batch' : 'Confirm & add';
}

/// Inventory requires a human-readable medicine name, but medicine packs often
/// print only one product identity string. Prefer a separately extracted name
/// only when it crossed the same review-confidence boundary as other identity
/// facts. Otherwise a trusted Brand is the safest visible name; this avoids a
/// weak OCR heading silently overriding a stronger, reviewed trade identity.
String confirmedScanName(MedicineScanDraft draft) {
  final nameField = draft.field('name');
  final name = nameField.value.trim();
  if (name.isNotEmpty &&
      !nameField.conflicted &&
      nameField.confidence >= .78) {
    return name;
  }
  return draft.brand.trim();
}

String _trustedIdentityFieldIssue(
  MedicineScanDraft draft,
  String key,
  String label,
) {
  final field = draft.field(key);
  if (field.value.trim().isEmpty) {
    return '$label still needs review before one-tap add.';
  }
  if (field.conflicted) {
    return '$label evidence conflicts and needs review before one-tap add.';
  }
  if (field.confidence < .78) {
    return '$label confidence is too low for one-tap add. Review the captured evidence first.';
  }
  return '';
}

String _explicitSourceForm(MedicineScanDraft draft) {
  final source = normalize(draft.rawText);
  if (source.isEmpty) return '';

  bool contains(String expression) => RegExp(expression).hasMatch(source);

  // Route-defining phrases outrank generic physical-form words. This keeps
  // POWDER FOR INJECTION as Injection and dry-powder inhalers as Inhaler while
  // still distinguishing oral Suspension from Syrup and Solution.
  if (contains(r'\b(?:powder|solution)\s+for\s+injection\b') ||
      contains(r'\bfor\s+injection\b')) {
    return 'Injection';
  }
  if (contains(r'\binhalers?\b')) return 'Inhaler';

  final forms = <String>{};
  void add(String expression, String form) {
    if (contains(expression)) forms.add(form);
  }

  add(r'\btablets?\b|\btabs?\b', 'Tablet');
  add(r'\bcapsules?\b|\bcaps?\b', 'Capsule');
  add(r'\bsyrups?\b', 'Syrup');
  add(r'\bsuspensions?\b', 'Suspension');
  add(r'\bsolutions?\b', 'Solution');
  add(r'\binjections?\b|\binjectable\b', 'Injection');
  add(r'\bcreams?\b', 'Cream');
  add(r'\bointments?\b', 'Ointment');
  add(r'\bgels?\b', 'Gel');
  add(r'\blotions?\b', 'Lotion');
  add(r'\bdrops?\b', 'Drops');
  add(r'\bsprays?\b', 'Spray');
  add(r'\bpowders?\b', 'Powder');
  add(r'\bsachets?\b', 'Sachet');

  return forms.length == 1 ? forms.single : '';
}

/// Returns the form that is safe to persist after preview confirmation.
///
/// A single explicit form token in raw OCR is deterministic evidence and can
/// repair a lower-confidence parser normalization (notably Suspension vs Syrup).
/// If raw text is ambiguous, only a strong, non-conflicted extracted field is
/// accepted. This keeps no-AI fallback useful without letting route-changing
/// form guesses pass the write boundary.
String confirmedScanForm(MedicineScanDraft draft) {
  final field = draft.field('form');
  if (field.conflicted) return '';

  final sourceForm = _explicitSourceForm(draft);
  if (sourceForm.isNotEmpty) return sourceForm;

  final rawForm = field.value.trim();
  if (rawForm.isEmpty || field.confidence < .78) return '';
  final normalized = normalizeForm(rawForm);
  if (normalized.isEmpty ||
      (normalized == 'Other' && normalize(rawForm) != 'other')) {
    return '';
  }
  return normalized;
}

/// One authoritative identity gate for every fast scan-to-stock entry point.
///
/// The UI may render richer warnings, but it must never be the only place that
/// enforces the four pharmacy identity facts promised by the scan journey. This
/// keeps future buttons/background entry points from accidentally allowing a
/// partial, low-confidence or conflicted AI/OCR draft simply because text was
/// present in a field.
String scanQuickIdentityIssue(MedicineScanDraft draft) {
  for (final requirement in const <(String, String)>[
    ('brand', 'Brand'),
    ('salt', 'Salt'),
    ('strength', 'Strength'),
  ]) {
    final issue = _trustedIdentityFieldIssue(
      draft,
      requirement.$1,
      requirement.$2,
    );
    if (issue.isNotEmpty) return issue;
  }

  if (confirmedScanName(draft).isEmpty) {
    return 'Medicine name or brand still needs review before this scan can be added.';
  }

  final formField = draft.field('form');
  if (formField.conflicted) {
    return 'Dosage form evidence conflicts and needs review before one-tap add.';
  }
  if (confirmedScanForm(draft).isEmpty) {
    return 'Dosage form is not recognized strongly enough for one-tap add.';
  }
  return '';
}

bool scanQuickIdentityReady(MedicineScanDraft draft) =>
    scanQuickIdentityIssue(draft).isEmpty;

ScanQuickAddDecision scanQuickAddDecision(
  MedicineScanDraft draft,
  IntakeResolution resolution,
) {
  final identityIssue = scanQuickIdentityIssue(draft);
  if (identityIssue.isNotEmpty) {
    return ScanQuickAddDecision.blocked(identityIssue);
  }

  final isNewStock = resolution.kind == IntakeResolutionKind.newStock;
  // Same-product one-tap creation is intentionally narrower than ordinary new
  // stock: EXP/MFG alone are product/lot evidence but are not unique physical
  // lot identifiers. A trusted printed batch is required so two packs sharing
  // an expiry month cannot silently become duplicate stock rows.
  final isPossibleNewBatch =
      resolution.kind == IntakeResolutionKind.sameProduct &&
      _hasTrustedBatchAnchor(draft);
  if (!isNewStock && !isPossibleNewBatch) {
    return const ScanQuickAddDecision.blocked(
      'Choose or verify the existing stock row before creating another entry.',
    );
  }

  for (final key in const ['mfg', 'expiry', 'batchNumber']) {
    final field = draft.field(key);
    if (field.value.trim().isNotEmpty && field.conflicted) {
      return const ScanQuickAddDecision.blocked(
        'Lot/date evidence conflicts and needs manual review first.',
      );
    }
  }

  try {
    final mfg = _scanDate(draft.mfg, monthOnly: draft.mfgMonthOnly);
    final expiry = _scanDate(
      draft.expiry,
      monthOnly: draft.expiryMonthOnly,
      expiry: true,
    );
    if (mfg != null && expiry != null && mfg.isAfter(expiry)) {
      return const ScanQuickAddDecision.blocked(
        'Manufacturing date is after expiry; verify the printed dates first.',
      );
    }
  } on FormatException {
    return const ScanQuickAddDecision.blocked(
      'A captured date is not valid enough for one-tap add.',
    );
  }

  return ScanQuickAddDecision.allowed(isNewBatch: isPossibleNewBatch);
}

bool _hasTrustedBatchAnchor(MedicineScanDraft draft) {
  final field = draft.field('batchNumber');
  return field.value.trim().isNotEmpty &&
      !field.conflicted &&
      field.confidence >= .82;
}

DateTime? _scanDate(
  String raw, {
  required bool monthOnly,
  bool expiry = false,
}) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  return parseDate(
    value,
    monthEnd: expiry && monthOnly,
    monthStart: !expiry && monthOnly,
  );
}

Medicine medicineFromConfirmedScan(MedicineScanDraft draft) {
  // Defense in depth: every present/future caller must cross the exact same
  // Brand + Salt + Strength + Form identity boundary as the visible one-tap UI.
  // Do not rely on a button having called scanQuickAddDecision first; background
  // or refactored entry points must never persist a partial AI/OCR identity.
  final identityIssue = scanQuickIdentityIssue(draft);
  if (identityIssue.isNotEmpty) {
    throw FormatException(identityIssue);
  }

  final name = confirmedScanName(draft);
  final form = confirmedScanForm(draft);
  final mfg = _scanDate(draft.mfg, monthOnly: draft.mfgMonthOnly);
  final expiry = _scanDate(
    draft.expiry,
    monthOnly: draft.expiryMonthOnly,
    expiry: true,
  );
  if (mfg != null && expiry != null && mfg.isAfter(expiry)) {
    throw const FormatException(
      'Manufacturing date cannot be after the expiry date.',
    );
  }

  return Medicine(
    id: newId(),
    name: name,
    brand: draft.brand.trim(),
    manufacturer: draft.manufacturer.trim(),
    salt: draft.salt.trim(),
    strength: draft.strength.trim(),
    form: form,
    mfg: mfg,
    mfgMonthOnly: draft.mfgMonthOnly,
    expiry: expiry,
    expiryMonthOnly: draft.expiryMonthOnly,
    barcode: draft.barcode.trim(),
    batchNumber: draft.batchNumber.trim(),
    ocrText: draft.searchableOcrText,
  );
}
