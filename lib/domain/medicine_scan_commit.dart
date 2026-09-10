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
/// print only one product identity string. When OCR/Local AI has a supported
/// Brand but no separate Name label, use that same reviewed Brand as the stored
/// display name. This removes pointless manual typing without inventing a fact:
/// the Brand remains visible in the preview and the user still confirms the
/// exact draft before any write.
String confirmedScanName(MedicineScanDraft draft) {
  final name = draft.name.trim();
  if (name.isNotEmpty) return name;
  return draft.brand.trim();
}

/// One authoritative identity gate for every fast scan-to-stock entry point.
///
/// The UI may render richer warnings, but it must never be the only place that
/// enforces the four pharmacy identity facts promised by the scan journey. This
/// keeps future buttons/background entry points from accidentally allowing a
/// partial AI draft simply because a display name happened to be present.
String scanQuickIdentityIssue(MedicineScanDraft draft) {
  if (confirmedScanName(draft).isEmpty) {
    return 'Medicine name or brand still needs review before this scan can be added.';
  }
  if (draft.brand.trim().isEmpty) {
    return 'Brand still needs review before one-tap add.';
  }
  if (draft.salt.trim().isEmpty) {
    return 'Salt still needs review before one-tap add.';
  }
  if (draft.strength.trim().isEmpty) {
    return 'Strength still needs review before one-tap add.';
  }

  final rawForm = draft.form.trim();
  if (rawForm.isEmpty) {
    return 'Dosage form still needs review before one-tap add.';
  }
  final normalizedForm = normalizeForm(rawForm);
  if (normalizedForm.isEmpty ||
      (normalizedForm == 'Other' && normalize(rawForm) != 'other')) {
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
  final name = confirmedScanName(draft);
  if (name.isEmpty) {
    throw const FormatException(
      'Medicine name or brand is required before adding stock.',
    );
  }

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

  final rawForm = draft.form.trim();
  final normalizedForm = normalizeForm(rawForm);
  return Medicine(
    id: newId(),
    name: name,
    brand: draft.brand.trim(),
    manufacturer: draft.manufacturer.trim(),
    salt: draft.salt.trim(),
    strength: draft.strength.trim(),
    form: rawForm.isEmpty ? '' : normalizedForm,
    mfg: mfg,
    mfgMonthOnly: draft.mfgMonthOnly,
    expiry: expiry,
    expiryMonthOnly: draft.expiryMonthOnly,
    barcode: draft.barcode.trim(),
    batchNumber: draft.batchNumber.trim(),
    ocrText: draft.searchableOcrText,
  );
}
