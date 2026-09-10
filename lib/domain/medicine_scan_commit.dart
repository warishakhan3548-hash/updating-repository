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

  String get actionLabel => isNewBatch ? 'Confirm & add new batch' : 'Confirm & add';
}

ScanQuickAddDecision scanQuickAddDecision(
  MedicineScanDraft draft,
  IntakeResolution resolution,
) {
  if (draft.name.trim().isEmpty) {
    return const ScanQuickAddDecision.blocked(
      'Medicine name still needs review before this scan can be added.',
    );
  }

  final isNewStock = resolution.kind == IntakeResolutionKind.newStock;
  final isPossibleNewBatch =
      resolution.kind == IntakeResolutionKind.sameProduct &&
      _hasTrustedLotAnchor(draft);
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

bool _hasTrustedLotAnchor(MedicineScanDraft draft) {
  for (final key in const ['batchNumber', 'expiry', 'mfg']) {
    final field = draft.field(key);
    if (field.value.trim().isNotEmpty &&
        !field.conflicted &&
        field.confidence >= .82) {
      return true;
    }
  }
  return false;
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
  final name = draft.name.trim();
  if (name.isEmpty) {
    throw const FormatException('Medicine name is required before adding stock.');
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
