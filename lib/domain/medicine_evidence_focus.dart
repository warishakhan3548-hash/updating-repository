import 'dart:math';

import 'medicine_understanding.dart';
import 'search.dart';

/// Raw OCR is an audit/search artifact; focused evidence is the much smaller
/// deterministic view allowed to influence medicine identity. Never delete raw
/// OCR merely because it looks like browser chrome, a timestamp, or packaging
/// noise: future search may still need those exact broken words.
const medicineEvidenceFocusMarker =
    '\n\n--- AARIS MEDICINE EVIDENCE FOCUS ---\n';
const maxPersistedRawOcrCharacters = 120000;

String rawOcrTextFromDraft(String value) {
  final marker = value.indexOf(medicineEvidenceFocusMarker);
  return (marker < 0 ? value : value.substring(0, marker)).trim();
}

String medicineDecisionTextFromDraft(String value) {
  final marker = value.indexOf(medicineEvidenceFocusMarker);
  return (marker < 0
          ? value
          : value.substring(marker + medicineEvidenceFocusMarker.length))
      .trim();
}

String composeRawAndFocusedOcr({
  required String rawOcr,
  required String focusedEvidence,
}) {
  final raw = _bounded(rawOcr.trim(), maxPersistedRawOcrCharacters);
  final focused = focusedEvidence.trim();
  if (raw.isEmpty) return focused;
  if (focused.isEmpty || searchText(raw) == searchText(focused)) return raw;

  // The raw side owns almost the entire persistence budget. Focused evidence is
  // small by design and is appended only so downstream deterministic validators
  // and optional local AI can consume the exact same product-focused view.
  const focusBudget = 12000;
  final safeFocus = _bounded(focused, focusBudget);
  final availableRaw = max(
    0,
    maxPersistedRawOcrCharacters -
        medicineEvidenceFocusMarker.length -
        safeFocus.length,
  );
  return '${_bounded(raw, availableRaw)}$medicineEvidenceFocusMarker$safeFocus';
}

String searchableRawOcrText(MedicineScanDraft draft) {
  final raw = rawOcrTextFromDraft(draft.rawText);
  final keywords = draft.searchKeywords.trim();
  if (keywords.isEmpty || searchText(raw).contains(searchText(keywords))) {
    return _bounded(raw, maxPersistedRawOcrCharacters);
  }
  return _bounded(
    '$raw\nSearch keywords: $keywords'.trim(),
    maxPersistedRawOcrCharacters,
  );
}

List<MedicineFrameEvidence> focusMedicineEvidence(
  Iterable<MedicineFrameEvidence> source,
) => source
    .take(maxMedicineEvidenceFrames)
    .map(focusMedicineFrameEvidence)
    .toList(growable: false);

MedicineFrameEvidence focusMedicineFrameEvidence(MedicineFrameEvidence frame) {
  final layout = frame.layoutLines
      .where((line) => line.text.trim().isNotEmpty && line.height > 0)
      .take(240)
      .toList(growable: false);

  // Pasted lists and structured text imports deliberately have no geometry.
  // Their explicit row boundaries are already high-quality evidence, so do not
  // apply screenshot heuristics to them.
  if (layout.length < 2) {
    return MedicineFrameEvidence(
      barcode: frame.barcode,
      barcodes: frame.barcodes,
      layoutLines: frame.layoutLines,
      text: _bounded(frame.text, 30000),
      source: frame.source,
      sequence: frame.sequence,
      timestampMs: frame.timestampMs,
      quality: frame.quality,
      startsNewItem: frame.startsNewItem,
    );
  }

  final ordered = [...layout]
    ..sort((a, b) {
      final top = a.top.compareTo(b.top);
      return top != 0 ? top : a.left.compareTo(b.left);
    });
  final heights = ordered.map((line) => line.height).toList()..sort();
  final medianHeight = max(1.0, heights[heights.length ~/ 2]);
  final minTop = ordered.map((line) => line.top).reduce(min);
  final maxBottom = ordered.map((line) => line.top + line.height).reduce(max);
  final verticalSpan = max(medianHeight * 8, maxBottom - minTop);

  final anchors = <MedicineTextLineEvidence>[];
  for (final line in ordered) {
    if (_uiOrWebNoise(line.text)) continue;
    if (_anchorScore(line.text) >= 3) anchors.add(line);
  }

  final selected = <MedicineTextLineEvidence>[];
  if (anchors.isEmpty) {
    // Fail soft: preserve non-UI OCR rather than pretending we know the pack ROI.
    selected.addAll(ordered.where((line) => !_uiOrWebNoise(line.text)));
  } else {
    final verticalWindow = max(medianHeight * 6.5, verticalSpan * .24);
    for (final line in ordered) {
      if (_uiOrWebNoise(line.text)) continue;
      final ownScore = _anchorScore(line.text);
      final nearby = anchors.any(
        (anchor) =>
            _verticalDistance(line, anchor) <= verticalWindow &&
            _horizontalAffinity(line, anchor),
      );
      if (!nearby && ownScore < 3) continue;

      // A total dry-powder/reconstitution amount such as 12 gm / 30 ml can sit
      // directly above the medicine name. Geometry alone cannot turn that pack
      // metric into therapeutic strength, so remove it from decision evidence.
      // The exact line remains untouched in the raw OCR/search channel.
      if (_unsafeStandalonePackDose(line.text)) continue;
      selected.add(line);
    }
  }

  final text = _dedupeFocusedLines(selected.map((line) => line.text));
  return MedicineFrameEvidence(
    barcode: frame.barcode,
    barcodes: frame.barcodes,
    layoutLines: selected.take(240).toList(growable: false),
    text: text.isEmpty ? _fallbackText(frame.text) : text,
    source: frame.source,
    sequence: frame.sequence,
    timestampMs: frame.timestampMs,
    quality: frame.quality,
    startsNewItem: frame.startsNewItem,
  );
}

String _fallbackText(String raw) {
  final lines = raw
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) =>
          line.isNotEmpty &&
          !_uiOrWebNoise(line) &&
          !_unsafeStandalonePackDose(line))
      .take(160);
  return _bounded(lines.join('\n'), 30000);
}

String _dedupeFocusedLines(Iterable<String> source) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in source) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final key = searchText(line);
    if (key.length < 2 || !seen.add(key)) continue;
    result.add(line);
  }
  return _bounded(result.join('\n'), 30000);
}

double _verticalDistance(
  MedicineTextLineEvidence a,
  MedicineTextLineEvidence b,
) {
  final ac = a.top + a.height / 2;
  final bc = b.top + b.height / 2;
  return (ac - bc).abs();
}

bool _horizontalAffinity(
  MedicineTextLineEvidence a,
  MedicineTextLineEvidence b,
) {
  final aLeft = a.left, aRight = a.left + a.width;
  final bLeft = b.left, bRight = b.left + b.width;
  final overlap = min(aRight, bRight) - max(aLeft, bLeft);
  if (overlap > 0) return true;
  final ac = (aLeft + aRight) / 2;
  final bc = (bLeft + bRight) / 2;
  final scale = max(max(a.width, b.width), 1.0);
  return (ac - bc).abs() <= scale * .8;
}

int _anchorScore(String raw) {
  final text = searchText(raw);
  if (text.isEmpty || _uiOrWebNoise(raw)) return -20;
  var score = 0;
  if (_compositionCue.hasMatch(text)) score += 5;
  if (_ingredientOrCompositionContext(raw)) score += 3;
  if (_doseCue.hasMatch(raw)) score += 3;
  if (_formCue.hasMatch(text)) score += 3;
  if (_dateOrBatchCue.hasMatch(text)) score += 2;
  if (_packLegalNoise.hasMatch(text)) score -= 2;
  if (_promotionalNoise.hasMatch(text)) score -= 5;
  if (_unsafeStandalonePackDose(raw)) score -= 8;
  return score;
}

bool _ingredientOrCompositionContext(String raw) {
  final text = searchText(raw);
  return _compositionCue.hasMatch(text) ||
      _formCue.hasMatch(text) ||
      RegExp(r'\b(?:ip|bp|usp|generic|active|ingredient|contains|equivalent)\b')
          .hasMatch(text);
}

bool _unsafeStandalonePackDose(String raw) {
  final text = searchText(raw);
  if (_compositionCue.hasMatch(text)) return false;
  // Total dry-powder/reconstitution amounts such as 12 gm / 30 ml are common
  // pack facts. They must not become therapeutic strength without explicit
  // same-line composition evidence. A normal 125 mg/5 ml dose is not caught.
  return RegExp(
    r'\b\d+(?:\.\d+)?\s*(?:gm|g)\s*/\s*\d+(?:\.\d+)?\s*ml\b',
    caseSensitive: false,
  ).hasMatch(raw);
}

bool _uiOrWebNoise(String raw) {
  final compact = raw.trim();
  if (compact.isEmpty) return true;
  final text = searchText(compact);
  if (RegExp(
    r'https?://|www\.|\bgoogle\.[a-z]{2,}\b|\b[a-z0-9.-]+\.(?:com|in|org|net)(?:/|\b)',
    caseSensitive: false,
  ).hasMatch(compact)) {
    return true;
  }
  if (RegExp(
    r'^\d{1,2}:\d{2}(?::\d{2})?(?:\s*[ap]m?)?$',
    caseSensitive: false,
  ).hasMatch(compact)) {
    return true;
  }
  if (_uiChrome.hasMatch(text)) return true;
  return false;
}

String _bounded(String value, int limit) =>
    value.length <= limit ? value : value.substring(0, limit);

final _compositionCue = RegExp(
  r'\b(?:composition|compositon|contains|active ingredient|active ingredients|generic name|salt|each tablet|each capsule|each 5 ml|equivalent to)\b',
  caseSensitive: false,
);
final _doseCue = RegExp(
  r'(?<![\d.,])\d+(?:\.\d+)?\s*(?:mcg|mg|gm|g|ml|iu|units?|%)(?:\s*/\s*(?:\d+(?:\.\d+)?\s*)?(?:ml|g))?(?![a-z\d/])',
  caseSensitive: false,
);
final _formCue = RegExp(
  r'\b(?:tablet|tablets|capsule|capsules|syrup|suspension|solution|injection|cream|ointment|gel|lotion|drop|drops|spray|inhaler|powder|sachet|dry syrup)\b',
  caseSensitive: false,
);
final _dateOrBatchCue = RegExp(
  r'\b(?:exp|expiry|expires|mfg|mfd|manufactured|manufacturing|batch|b no|lot|lot no)\b',
  caseSensitive: false,
);
final _uiChrome = RegExp(
  r'^(?:home|shorts|subscriptions?|subscribe|share|save|live|trends?|lens|search|use template|auto dubbed|comments?|you)$',
  caseSensitive: false,
);
final _promotionalNoise = RegExp(
  r'\b(?:benefits?|uses?|fayde|फायदे|subscribe|follow|like|share)\b',
  caseSensitive: false,
);
final _packLegalNoise = RegExp(
  r'\b(?:keep out of reach|store in|schedule|regd trade mark|licence|license|for sale|physician|dosage as directed)\b',
  caseSensitive: false,
);
