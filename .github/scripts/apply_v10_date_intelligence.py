from pathlib import Path


def read(path):
    return Path(path).read_text()


def write(path, value):
    Path(path).write_text(value)


def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one anchor, found {count}: {old[:100]!r}")
    write(path, text.replace(old, new, 1))


resolution = 'lib/domain/medicine_resolution_v2.dart'
replace_once(
    resolution,
    "import 'medicine.dart';\nimport 'medicine_confusion_firewall.dart';\nimport 'medicine_understanding.dart';",
    "import 'medicine.dart';\nimport 'medicine_confusion_firewall.dart';\nimport 'medicine_date_intelligence.dart';\nimport 'medicine_understanding.dart';",
)
replace_once(
    resolution,
    """      final spatialSafe = _applySpatialTraceability(draft, frames);
      final regulatorySafe = _applyRegulatoryTraceability(spatialSafe, frames);
      drafts.add(_resolveProduct(regulatorySafe, frames));""",
    """      final spatialSafe = _applySpatialTraceability(draft, frames);
      final regulatorySafe = _applyRegulatoryTraceability(spatialSafe, frames);
      final temporalSafe = _applyDateIntelligence(regulatorySafe, frames);
      drafts.add(_resolveProduct(temporalSafe, frames));""",
)

helper = r'''MedicineScanDraft _applyDateIntelligence(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final intelligence = inferMedicineDateIntelligence(
    frames: frames,
    referenceDate: DateTime.now(),
    existingMfg: draft.mfg,
    existingExpiry: draft.expiry,
    existingMfgConfidence: draft.field('mfg').confidence,
    existingExpiryConfidence: draft.field('expiry').confidence,
  );
  if (intelligence.isEmpty) return draft;

  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);

  void apply(String key, MedicineDateEvidence? suggestion) {
    if (suggestion == null || suggestion.confidence < .78) return;
    final current = fields[key];
    final currentDate = current == null
        ? null
        : parseMedicineDateText(current.value);
    final same = currentDate?.value == suggestion.date.value;
    if (same) {
      fields[key] = ExtractedMedicineField(
        value: suggestion.date.value,
        confidence: max(current?.confidence ?? 0, suggestion.confidence),
        support: max(current?.support ?? 0, suggestion.support),
        conflicted: current?.conflicted == true,
      );
      return;
    }

    if (current != null && !current.isEmpty && current.confidence >= .86) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: min(current.confidence, .84),
        support: max(current.support, suggestion.support),
        conflicted: true,
      );
      return;
    }

    fields[key] = ExtractedMedicineField(
      value: suggestion.date.value,
      confidence: suggestion.confidence.clamp(.78, .96).toDouble(),
      support: max(current?.support ?? 0, suggestion.support),
      conflicted: false,
    );
  }

  apply('mfg', intelligence.manufacturing);
  apply('expiry', intelligence.expiry);

  if (intelligence.conflicted) {
    for (final key in const <String>['mfg', 'expiry']) {
      final field = fields[key];
      if (field == null || field.isEmpty) continue;
      fields[key] = ExtractedMedicineField(
        value: field.value,
        confidence: min(field.confidence, .80),
        support: field.support,
        conflicted: true,
      );
    }
  }

  return _copyDraft(
    draft,
    fields: fields,
    overallConfidence: intelligence.conflicted
        ? min(draft.overallConfidence, .77)
        : draft.overallConfidence,
  );
}

'''
replace_once(
    resolution,
    'MedicineScanDraft _applySpatialTraceability(\n',
    helper + 'MedicineScanDraft _applySpatialTraceability(\n',
)

spatial = 'lib/domain/spatial_traceability.dart'
replace_once(
    spatial,
    "import 'medicine_understanding.dart';\nimport 'offline_evidence_graph.dart';",
    "import 'medicine_date_intelligence.dart';\nimport 'medicine_understanding.dart';\nimport 'offline_evidence_graph.dart';",
)
text = read(spatial)
start = text.find('String _extractDate(String raw) {')
iso_start = text.find('\nString _isoDate(', start)
geometry_start = text.find('\ndouble _geometryScore(', iso_start)
if start < 0 or iso_start < 0 or geometry_start < 0:
    raise SystemExit('spatial_traceability.dart: date helper anchors missing')
replacement = r'''String _extractDate(String raw) {
  final parsed = parseMedicineDateText(raw);
  return parsed?.value ?? '';
}
'''
# Replace the old extractor and remove the now-dead private ISO helper. V10's
# shared parser is the single date normalizer for both spatial and temporal lanes.
write(spatial, text[:start] + replacement + text[geometry_start + 1:])

print('V10 date intelligence integration applied')
