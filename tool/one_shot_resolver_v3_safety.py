from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / 'lib/domain/medicine_resolution_v2.dart'
text = path.read_text(encoding='utf-8')

old_margin = '''    final margin = runnerUp == null ? 1.0 : winner.score - runnerUp.score;\n\n    if (winner.hardConflicts > 0) {\n'''
new_margin = '''    final margin = runnerUp == null ? 1.0 : winner.score - runnerUp.score;\n    // A barcode identifies a product only when that mapping is unique, or when\n    // independent printed evidence resolves the duplicate mapping. Retail and\n    // legacy catalogues can contain the same GTIN against multiple variants; a\n    // tie must never become a deterministic auto-fill merely because sorting\n    // happened to put one product first.\n    final exactBarcodeAmbiguous = winner.exactBarcode &&\n        hypotheses.skip(1).any(\n          (candidate) =>\n              candidate.exactBarcode &&\n              !_sameResolvedProductIdentity(winner.product, candidate.product),\n        );\n\n    if (winner.hardConflicts > 0) {\n'''
if text.count(old_margin) != 1:
    raise SystemExit('Resolver margin anchor changed; refusing unsafe patch.')
text = text.replace(old_margin, new_margin, 1)

old_lock = '''    final exactBarcodeLock =\n        winner.exactBarcode && winner.product.verified && winner.hardConflicts == 0;\n'''
new_lock = '''    final exactBarcodeLock =\n        winner.exactBarcode &&\n        !exactBarcodeAmbiguous &&\n        winner.product.verified &&\n        winner.hardConflicts == 0;\n'''
if text.count(old_lock) != 1:
    raise SystemExit('Exact barcode lock anchor changed; refusing unsafe patch.')
text = text.replace(old_lock, new_lock, 1)

start = text.index('MedicineScanDraft _applyGs1Traceability(')
end = text.index('\nString _gs1Date(String value)', start)
replacement = r'''MedicineScanDraft _applyGs1Traceability(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final gtins = <String>{};
  final batches = <String>{};
  final mfgs = <String>{};
  final expiries = <String>{};
  for (final frame in frames) {
    for (final raw in frame.allBarcodes) {
      final gs1 = parseGs1HealthcareBarcode(raw);
      if (gs1 == null) continue;
      if (gs1.gtin.isNotEmpty) gtins.add(gs1.gtin);
      if (gs1.batchLot.isNotEmpty) batches.add(gs1.batchLot.trim());
      if (gs1.manufacturingYyMmDd.isNotEmpty) {
        final value = _gs1Date(gs1.manufacturingYyMmDd);
        if (value.isNotEmpty) mfgs.add(value);
      }
      if (gs1.expiryYyMmDd.isNotEmpty) {
        final value = _gs1Date(gs1.expiryYyMmDd);
        if (value.isNotEmpty) expiries.add(value);
      }
    }
  }
  if (gtins.isEmpty && batches.isEmpty && mfgs.isEmpty && expiries.isEmpty) {
    return draft;
  }

  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  var structuredConflict = false;

  double conflictFloor(String key) => switch (key) {
    'barcode' => .82,
    'batchNumber' => .78,
    'mfg' || 'expiry' => .78,
    _ => .82,
  };

  void apply(String key, Set<String> values) {
    if (values.isEmpty) return;
    final ordered = values.toList()..sort();
    final current = fields[key];
    if (ordered.length > 1) {
      structuredConflict = true;
      final value = current?.value.trim().isNotEmpty == true
          ? current!.value
          : ordered.first;
      fields[key] = ExtractedMedicineField(
        value: value,
        confidence: min(current?.confidence ?? .90, .90),
        support: max(current?.support ?? 0, ordered.length),
        conflicted: true,
      );
      return;
    }

    final value = ordered.single;
    final priorConflict = current?.conflicted == true;
    final conflict =
        current != null &&
        !current.isEmpty &&
        current.confidence >= conflictFloor(key) &&
        !_structuredFieldCompatible(key, current.value, value);
    if (priorConflict || conflict) structuredConflict = true;

    // Valid GS1 remains the displayed structured fact, but disagreement with
    // credible printed OCR is surfaced as review state rather than silently
    // erasing the contradictory observation.
    fields[key] = ExtractedMedicineField(
      value: value,
      confidence: (priorConflict || conflict) ? .82 : .995,
      support: max(1, current?.support ?? 0),
      conflicted: priorConflict || conflict,
    );
  }

  apply('barcode', gtins);
  apply('batchNumber', batches);
  apply('mfg', mfgs);
  apply('expiry', expiries);

  final mfg = fields['mfg'];
  final expiry = fields['expiry'];
  if (mfg != null &&
      expiry != null &&
      !mfg.isEmpty &&
      !expiry.isEmpty &&
      _invalidStructuredChronology(mfg.value, expiry.value)) {
    structuredConflict = true;
    for (final key in const <String>['mfg', 'expiry']) {
      final field = fields[key]!;
      fields[key] = ExtractedMedicineField(
        value: field.value,
        confidence: min(field.confidence, .82),
        support: field.support,
        conflicted: true,
      );
    }
  }

  return _copyDraft(
    draft,
    fields: fields,
    overallConfidence: structuredConflict
        ? min(draft.overallConfidence, .77)
        : draft.overallConfidence,
  );
}

bool _structuredFieldCompatible(String field, String observed, String structured) {
  if (field == 'mfg' || field == 'expiry') {
    final pattern = RegExp(r'^(\d{4})-(\d{2})(?:-(\d{2}))?$');
    final left = pattern.firstMatch(observed.trim());
    final right = pattern.firstMatch(structured.trim());
    if (left != null &&
        right != null &&
        left.group(1) == right.group(1) &&
        left.group(2) == right.group(2)) {
      final leftDay = left.group(3);
      final rightDay = right.group(3);
      if (leftDay == null || rightDay == null || leftDay == rightDay) {
        return true;
      }
    }
  }
  return _fieldIdentity(field, observed) == _fieldIdentity(field, structured);
}

bool _invalidStructuredChronology(String mfg, String expiry) {
  final pattern = RegExp(r'^(\d{4})-(\d{2})(?:-(\d{2}))?$');
  final left = pattern.firstMatch(mfg.trim());
  final right = pattern.firstMatch(expiry.trim());
  if (left == null || right == null) return false;
  final leftMonth = int.parse(left.group(1)!) * 12 + int.parse(left.group(2)!);
  final rightMonth = int.parse(right.group(1)!) * 12 + int.parse(right.group(2)!);
  if (leftMonth != rightMonth) return leftMonth > rightMonth;
  final leftDay = int.tryParse(left.group(3) ?? '');
  final rightDay = int.tryParse(right.group(3) ?? '');
  return leftDay != null && rightDay != null && leftDay > rightDay;
}
'''
text = text[:start] + replacement + text[end:]
path.write_text(text, encoding='utf-8')
Path(__file__).unlink()
