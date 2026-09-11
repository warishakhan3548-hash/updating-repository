import 'intake_resolution.dart';
import 'medicine.dart';
import 'medicine_understanding.dart';

/// Final, deterministic gate between a scan preview and a one-tap inventory add.
///
/// AI/OCR may propose identity facts, but deterministic commit policy alone
/// authorizes creation. Human review remains the fail-closed fallback whenever
/// evidence, lot identity or chronology is weak. The controller's revision/CAS
/// boundary is the final authority at commit time.
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

/// Stronger machine-commit gate for the direct camera automation path.
///
/// Local AI is an evidence resolver, never an inventory writer. Automatic
/// persistence requires a scan-verified on-device model to have reviewed this
/// exact OCR draft, plus all pre-existing deterministic quick-add invariants.
class ScanAutoSaveDecision {
  const ScanAutoSaveDecision._({
    required this.allowed,
    required this.isNewBatch,
    required this.reason,
  });

  const ScanAutoSaveDecision.allowed({bool isNewBatch = false})
    : this._(allowed: true, isNewBatch: isNewBatch, reason: '');

  const ScanAutoSaveDecision.blocked(String reason)
    : this._(allowed: false, isNewBatch: false, reason: reason);

  final bool allowed;
  final bool isNewBatch;
  final String reason;
}

/// Inventory requires a human-readable medicine name, but medicine packs often
/// print only one product identity string. Prefer a separately extracted name
/// only when it crossed the same review-confidence boundary as other identity
/// facts. Otherwise a trusted Brand is the safest visible name; this avoids a
/// weak OCR heading silently overriding a stronger, reviewed trade identity.
String confirmedScanName(MedicineScanDraft draft) {
  final nameField = draft.field('name');
  final name = nameField.value.trim();
  if (name.isNotEmpty && !nameField.conflicted && nameField.confidence >= .78) {
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

List<String> _compositionParts(String value) => value
    .split(RegExp(r'\s*\+\s*'))
    .map((part) => part.trim())
    .where((part) => part.isNotEmpty)
    .toList(growable: false);

bool _hasExplicitStrengthUnit(String value) => RegExp(
  r'\d+(?:\.\d+)?\s*(?:mcg|µg|μg|ug|mg|gm|g|ml|iu|i\.u\.|units?|%)(?:\s*/\s*(?:\d+(?:\.\d+)?\s*)?(?:mcg|µg|μg|ug|mg|gm|g|ml|l|iu|i\.u\.|units?))?(?:\s*(?:w\s*/\s*v|w\s*/\s*w|v\s*/\s*v))?',
  caseSensitive: false,
).hasMatch(value);

/// Salt and strength are persisted as parallel, ordered composition lists.
/// Confidence on each field alone is not enough: a combination with two salts
/// and one aggregate/brand-looking number is unsafe even when an upstream model
/// labeled both strings confidently. Enforce pair arity and an explicit dose
/// unit at the final domain boundary so every current/future one-tap entry point
/// inherits the same no-guess rule.
String _compositionPairingIssue(MedicineScanDraft draft) {
  final salts = _compositionParts(draft.salt);
  final strengths = _compositionParts(draft.strength);
  if (salts.isEmpty || strengths.isEmpty) {
    return 'Salt and strength still need review before one-tap add.';
  }
  if (strengths.any((strength) => !_hasExplicitStrengthUnit(strength))) {
    return 'Strength needs an explicit printed dose unit before one-tap add; a brand or pack number is not enough.';
  }
  if ((salts.length > 1 || strengths.length > 1) &&
      salts.length != strengths.length) {
    return 'Combination salt and strength evidence does not pair one-to-one. Review the printed composition before one-tap add.';
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
/// A strong extracted form and an unambiguous source form are independent
/// evidence channels. Neither is allowed to silently override the other: if
/// both exist and disagree, one-tap add fails closed and detailed review owns
/// the decision. When extraction is weak/missing, one explicit source form can
/// still rescue the no-AI deterministic path without manual typing.
String confirmedScanForm(MedicineScanDraft draft) {
  final field = draft.field('form');
  if (field.conflicted) return '';

  final sourceForm = _explicitSourceForm(draft);
  final rawForm = field.value.trim();
  var extractedForm = '';
  if (rawForm.isNotEmpty && field.confidence >= .78) {
    final normalized = normalizeForm(rawForm);
    if (normalized.isNotEmpty &&
        (normalized != 'Other' || normalize(rawForm) == 'other')) {
      extractedForm = normalized;
    }
  }

  if (extractedForm.isNotEmpty &&
      sourceForm.isNotEmpty &&
      extractedForm != sourceForm) {
    return '';
  }
  if (extractedForm.isNotEmpty) return extractedForm;
  return sourceForm;
}

/// One authoritative identity gate for every fast scan-to-stock entry point.
///
/// The UI may render richer warnings, but it must never be the only place that
/// enforces the four pharmacy identity facts promised by the scan journey. This
/// keeps future buttons/background entry points from accidentally allowing a
/// partial, low-confidence or conflicted AI/OCR draft simply because text was
/// present in a field.
String scanQuickIdentityIssue(MedicineScanDraft draft) {
  // Product-level contradiction/ambiguity can lower the calibrated draft score
  // even when each visible identity field remains individually strong. Treat
  // that global signal as authoritative too; otherwise a wrong trusted GTIN or
  // future cross-field conflict could still unlock one-tap add.
  if (draft.overallConfidence < .78) {
    return 'This scan still has unresolved product-level uncertainty or conflicting evidence. Open detailed review before one-tap add.';
  }

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

  final compositionIssue = _compositionPairingIssue(draft);
  if (compositionIssue.isNotEmpty) return compositionIssue;

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

/// Lot/date integrity belongs at the domain boundary, not only in a button.
/// Every caller of medicineFromConfirmedScan() must therefore inherit the same
/// conflict, confidence, parse and chronology checks as the visible quick-add
/// decision. Optional lot facts may be omitted, but if shown in a one-tap
/// preview they must be strong enough to persist without silently saving a weak
/// OCR guess.
String _scanLotIssue(MedicineScanDraft draft) {
  for (final key in const ['mfg', 'expiry', 'batchNumber', 'barcode']) {
    final field = draft.field(key);
    if (field.value.trim().isEmpty) continue;
    if (field.conflicted) {
      return 'Lot/date/barcode evidence conflicts and needs manual review first.';
    }
    final minimumConfidence = key == 'batchNumber' || key == 'barcode'
        ? .82
        : .78;
    if (field.confidence < minimumConfidence) {
      return 'A captured lot/date/barcode fact is not confident enough for one-tap add. Review the printed evidence first.';
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
      return 'Manufacturing date is after expiry; verify the printed dates first.';
    }
  } on FormatException {
    return 'A captured date is not valid enough for one-tap add.';
  }
  return '';
}

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

  final lotIssue = _scanLotIssue(draft);
  if (lotIssue.isNotEmpty) {
    return ScanQuickAddDecision.blocked(lotIssue);
  }

  return ScanQuickAddDecision.allowed(isNewBatch: isPossibleNewBatch);
}

ScanAutoSaveDecision scanAutoSaveDecision(
  MedicineScanDraft draft,
  IntakeResolution resolution, {
  required bool localAiVerified,
}) {
  if (!localAiVerified) {
    return const ScanAutoSaveDecision.blocked(
      'A scan-verified Local AI did not verify this exact OCR draft. Review it before saving.',
    );
  }

  final quick = scanQuickAddDecision(draft, resolution);
  if (!quick.allowed) return ScanAutoSaveDecision.blocked(quick.reason);
  if (draft.rawText.trim().isEmpty) {
    return const ScanAutoSaveDecision.blocked(
      'Raw packaging evidence is missing, so automatic save is disabled.',
    );
  }
  if (draft.overallConfidence < .88) {
    return const ScanAutoSaveDecision.blocked(
      'The verified medicine identity is below the automatic-save confidence floor.',
    );
  }

  for (final requirement in const <(String, String)>[
    ('brand', 'Brand'),
    ('salt', 'Salt'),
    ('strength', 'Strength'),
    ('form', 'Dosage form'),
  ]) {
    final field = draft.field(requirement.$1);
    if (field.value.trim().isEmpty ||
        field.conflicted ||
        field.confidence < .88) {
      return ScanAutoSaveDecision.blocked(
        '${requirement.$2} is not strongly source-verified enough for automatic save.',
      );
    }
  }

  return ScanAutoSaveDecision.allowed(isNewBatch: quick.isNewBatch);
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

String _confirmedOptionalText(
  MedicineScanDraft draft,
  String key, {
  double minimumConfidence = .78,
}) {
  final field = draft.field(key);
  final value = field.value.trim();
  if (value.isEmpty ||
      field.conflicted ||
      field.confidence < minimumConfidence) {
    return '';
  }
  return value;
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
  final lotIssue = _scanLotIssue(draft);
  if (lotIssue.isNotEmpty) {
    throw FormatException(lotIssue);
  }

  final name = confirmedScanName(draft);
  final form = confirmedScanForm(draft);
  final mfg = _scanDate(draft.mfg, monthOnly: draft.mfgMonthOnly);
  final expiry = _scanDate(
    draft.expiry,
    monthOnly: draft.expiryMonthOnly,
    expiry: true,
  );

  return Medicine(
    id: newId(),
    name: name,
    brand: draft.brand.trim(),
    // Manufacturer is not part of the compact quick-add preview. Never persist
    // a weak/conflicted hidden optional value merely because identity passed.
    manufacturer: _confirmedOptionalText(draft, 'manufacturer'),
    salt: draft.salt.trim(),
    strength: draft.strength.trim(),
    form: form,
    mfg: mfg,
    mfgMonthOnly: draft.mfgMonthOnly,
    expiry: expiry,
    expiryMonthOnly: draft.expiryMonthOnly,
    barcode: _confirmedOptionalText(draft, 'barcode', minimumConfidence: .82),
    batchNumber: _confirmedOptionalText(
      draft,
      'batchNumber',
      minimumConfidence: .82,
    ),
    ocrText: draft.searchableOcrText,
  );
}
