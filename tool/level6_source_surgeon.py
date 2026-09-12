from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, value: str) -> None:
    Path(path).write_text(value)


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"{path}: expected exactly one anchor, found {count}: {old[:80]!r}"
        )
    write(path, text.replace(old, new, 1))


def replace_section(path: str, start: str, end: str, new: str) -> None:
    text = read(path)
    a = text.find(start)
    if a < 0:
        raise SystemExit(f"{path}: missing start anchor {start[:80]!r}")
    b = text.find(end, a)
    if b < 0:
        raise SystemExit(f"{path}: missing end anchor {end[:80]!r}")
    write(path, text[:a] + new + text[b:])


# Regulatory parser: Dart RegExp uses the caseSensitive option rather than an
# inline (?i) modifier; Uri.pathSegments are already decoded.
replace_once(
    "lib/domain/regulatory_medicine_code.dart",
    ".map(Uri.decodeComponent)",
    ".map((value) => value.trim())",
)
replace_once(
    "lib/domain/regulatory_medicine_code.dart",
    """  final matcher = RegExp(
    r'(?i)\\b(gtin|batch(?:\\s*(?:no|number))?|lot(?:\\s*no)?|mfg|mfd|manufacturing(?:\\s*date)?|exp|expiry|expiration(?:\\s*date)?|serial(?:\\s*(?:no|number))?)\\s*[:=]\\s*([^;|\\r\\n]{1,80})',
  );""",
    """  final matcher = RegExp(
    r'\\b(gtin|batch(?:\\s*(?:no|number))?|lot(?:\\s*no)?|mfg|mfd|manufacturing(?:\\s*date)?|exp|expiry|expiration(?:\\s*date)?|serial(?:\\s*(?:no|number))?)\\s*[:=]\\s*([^;|\\r\\n]{1,80})',
    caseSensitive: false,
  );""",
)

resolution = "lib/domain/medicine_resolution_v2.dart"
replace_once(
    resolution,
    """import 'gs1_healthcare.dart';
import 'medicine.dart';
import 'medicine_understanding.dart';
import 'offline_decision_reliability.dart';
import 'offline_evidence_graph.dart';
import 'search.dart';""",
    """import 'gs1_healthcare.dart';
import 'medicine.dart';
import 'medicine_confusion_firewall.dart';
import 'medicine_understanding.dart';
import 'offline_decision_reliability.dart';
import 'offline_evidence_graph.dart';
import 'regulatory_medicine_code.dart';
import 'search.dart';
import 'spatial_traceability.dart';""",
)

replace_once(
    resolution,
    """      final gs1Safe = _applyGs1Traceability(draft, frames);
      drafts.add(_resolveProduct(gs1Safe, frames));""",
    """      final spatialSafe = _applySpatialTraceability(draft, frames);
      final regulatorySafe = _applyRegulatoryTraceability(spatialSafe, frames);
      drafts.add(_resolveProduct(regulatorySafe, frames));""",
)

replace_once(
    resolution,
    """    final margin = runnerUp == null ? 1.0 : winner.score - runnerUp.score;

    if (winner.hardConflicts > 0) {""",
    """    final margin = runnerUp == null ? 1.0 : winner.score - runnerUp.score;
    final confusion = runnerUp == null
        ? null
        : assessMedicineConfusion(
            MedicineConfusionIdentity(
              name: winner.product.displayName,
              brand: winner.product.brand,
              salt: winner.product.salt,
              strength: winner.product.strength,
              form: winner.product.form,
            ),
            MedicineConfusionIdentity(
              name: runnerUp.product.displayName,
              brand: runnerUp.product.brand,
              salt: runnerUp.product.salt,
              strength: runnerUp.product.strength,
              form: runnerUp.product.form,
            ),
          );

    if (winner.hardConflicts > 0) {""",
)

replace_once(
    resolution,
    """    final requiredDecisionMass = _resolverRequiredDecisionMass(evidenceQuality);
    final selectiveReliability = assessOfflineDecisionReliability(""",
    """    final requiredDecisionMass = _resolverRequiredDecisionMass(evidenceQuality);
    final confusionSafe =
        confusion == null ||
        !confusion.highRisk ||
        exactBarcodeLock ||
        _confusionResolvedByEvidence(
          draft,
          winner.product,
          runnerUp!.product,
          confusion,
          winner,
          margin,
        );
    final selectiveReliability = assessOfflineDecisionReliability(""",
)
replace_once(
    resolution,
    """        winner.hardConflicts == 0 &&
        selectiveReliability.acceptCanonicalLock;""",
    """        winner.hardConflicts == 0 &&
        selectiveReliability.acceptCanonicalLock &&
        confusionSafe;""",
)
replace_once(
    resolution,
    """    if (exactBarcodeLock || calibratedLock) {
      return _inheritCanonicalIdentity(
        draft,
        winner,
        decisionReliability: selectiveReliability.score,
      );
    }

    // Low-quality evidence requires a wider separation before automation.""",
    """    if (exactBarcodeLock || calibratedLock) {
      return _inheritCanonicalIdentity(
        draft,
        winner,
        decisionReliability: selectiveReliability.score,
      );
    }

    if (runnerUp != null &&
        confusion != null &&
        confusion.highRisk &&
        !confusionSafe) {
      return _markProductAmbiguity(draft, winner.product, runnerUp.product);
    }

    // Low-quality evidence requires a wider separation before automation.""",
)

confusion_helper = r"""bool _confusionResolvedByEvidence(
  MedicineScanDraft draft,
  CanonicalMedicineProduct winner,
  CanonicalMedicineProduct alternative,
  MedicineConfusionAssessment assessment,
  _ProductHypothesis hypothesis,
  double margin,
) {
  if (assessment.criticalFields.isEmpty ||
      margin < .10 ||
      hypothesis.channels < 3 ||
      hypothesis.decisionMass < .52) {
    return false;
  }

  var confirmations = 0;
  for (final field in assessment.criticalFields) {
    final observed = draft.field(field);
    if (observed.isEmpty || observed.conflicted) continue;
    final minimumConfidence = field == 'strength' ? .65 : .78;
    if (observed.confidence < minimumConfidence) continue;

    bool winnerMatch;
    bool alternativeMatch;
    if (field == 'strength') {
      final key = _strengthIdentity(observed.value);
      winnerMatch = key.isNotEmpty && key == _strengthIdentity(winner.strength);
      alternativeMatch =
          key.isNotEmpty && key == _strengthIdentity(alternative.strength);
    } else if (field == 'form') {
      final key = normalizeForm(observed.value);
      winnerMatch = key.isNotEmpty && key == normalizeForm(winner.form);
      alternativeMatch = key.isNotEmpty && key == normalizeForm(alternative.form);
    } else {
      winnerMatch = _weightedTextSimilarity(observed.value, winner.salt) >= .88;
      alternativeMatch =
          _weightedTextSimilarity(observed.value, alternative.salt) >= .88;
    }
    if (alternativeMatch && !winnerMatch) return false;
    if (winnerMatch && !alternativeMatch) confirmations++;
  }

  final required = assessment.riskScore >= .88 &&
          assessment.criticalFields.length >= 2
      ? 2
      : 1;
  return confirmations >= min(required, assessment.criticalFields.length);
}

"""
replace_once(
    resolution,
    "bool _sameResolvedProductIdentity(\n",
    confusion_helper + "bool _sameResolvedProductIdentity(\n",
)

spatial_and_regulatory = r"""MedicineScanDraft _applySpatialTraceability(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final hints = inferSpatialTraceability(frames);
  if (hints.isEmpty) return draft;
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);

  void apply(String key, SpatialTraceabilityField? hint) {
    if (hint == null || hint.value.trim().isEmpty || hint.confidence < .80) {
      return;
    }
    final current = fields[key];
    final currentIdentity = current == null ? '' : _fieldIdentity(key, current.value);
    final hintIdentity = _fieldIdentity(key, hint.value);
    final strongConflict =
        current != null &&
        !current.isEmpty &&
        current.confidence >= .90 &&
        currentIdentity.isNotEmpty &&
        hintIdentity.isNotEmpty &&
        currentIdentity != hintIdentity;
    if (strongConflict) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: min(current.confidence, .84),
        support: max(current.support, hint.support),
        conflicted: true,
      );
      return;
    }
    if (hint.conflicted) {
      fields[key] = ExtractedMedicineField(
        value: current?.value.trim().isNotEmpty == true ? current!.value : hint.value,
        confidence: min(max(current?.confidence ?? 0, hint.confidence), .82),
        support: max(current?.support ?? 0, hint.support),
        conflicted: true,
      );
      return;
    }
    if (current == null ||
        current.isEmpty ||
        hint.confidence > current.confidence + .025) {
      fields[key] = ExtractedMedicineField(
        value: hint.value,
        confidence: hint.confidence.clamp(.80, .96).toDouble(),
        support: max(current?.support ?? 0, hint.support),
        conflicted: false,
      );
    }
  }

  apply('batchNumber', hints.batch);
  apply('mfg', hints.mfg);
  apply('expiry', hints.expiry);

  final mfg = fields['mfg'];
  final expiry = fields['expiry'];
  if (mfg != null && expiry != null && !mfg.isEmpty && !expiry.isEmpty) {
    try {
      final mfgDate = parseDate(mfg.value, monthStart: true);
      final expiryDate = parseDate(expiry.value, monthEnd: true);
      if (mfgDate != null && expiryDate != null && mfgDate.isAfter(expiryDate)) {
        fields['mfg'] = ExtractedMedicineField(
          value: mfg.value,
          confidence: min(mfg.confidence, .80),
          support: mfg.support,
          conflicted: true,
        );
        fields['expiry'] = ExtractedMedicineField(
          value: expiry.value,
          confidence: min(expiry.confidence, .80),
          support: expiry.support,
          conflicted: true,
        );
      }
    } on FormatException {
      // Invalid spatial candidates remain non-authoritative and reviewable.
    }
  }
  return _copyDraft(draft, fields: fields);
}

MedicineScanDraft _applyRegulatoryTraceability(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final gtins = <String>{};
  final batches = <String>{};
  final mfgs = <String>{};
  final expiries = <String>{};
  for (final frame in frames) {
    for (final raw in frame.allBarcodes) {
      final structured = parseRegulatoryMedicineCode(raw);
      if (structured == null) continue;
      if (structured.gtin.isNotEmpty) gtins.add(structured.gtin);
      if (structured.batchLot.isNotEmpty) batches.add(structured.batchLot.trim());
      if (structured.manufacturingYyMmDd.isNotEmpty) {
        final value = _gs1Date(structured.manufacturingYyMmDd);
        if (value.isNotEmpty) mfgs.add(value);
      }
      if (structured.expiryYyMmDd.isNotEmpty) {
        final value = _gs1Date(structured.expiryYyMmDd);
        if (value.isNotEmpty) expiries.add(value);
      }
    }
  }
  if (gtins.isEmpty && batches.isEmpty && mfgs.isEmpty && expiries.isEmpty) {
    return draft;
  }

  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  void apply(String key, Set<String> values) {
    if (values.isEmpty) return;
    final ordered = values.toList()..sort();
    final current = fields[key];
    if (ordered.length > 1) {
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
    final currentKey = current == null ? '' : _fieldIdentity(key, current.value);
    final structuredKey = _fieldIdentity(key, value);
    final conflict =
        current != null &&
        !current.isEmpty &&
        current.confidence >= .97 &&
        currentKey.isNotEmpty &&
        currentKey != structuredKey;
    fields[key] = ExtractedMedicineField(
      value: value,
      confidence: conflict ? .82 : .995,
      support: max(1, current?.support ?? 0),
      conflicted: conflict,
    );
  }

  apply('barcode', gtins);
  apply('batchNumber', batches);
  apply('mfg', mfgs);
  apply('expiry', expiries);
  return _copyDraft(draft, fields: fields);
}

"""
replace_section(
    resolution,
    "MedicineScanDraft _applyGs1Traceability(",
    "String _gs1Date(",
    spatial_and_regulatory,
)

replace_section(
    resolution,
    "String _canonicalBarcode(String value) {",
    "bool _isStrongProductBarcodeKey(String value) {",
    r"""String _canonicalBarcode(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final structured = parseRegulatoryMedicineCode(raw);
  final candidate = structured != null && structured.gtin.isNotEmpty
      ? structured.gtin
      : raw;
  if (RegExp(r'^\d+$').hasMatch(candidate) &&
      const <int>{8, 12, 13, 14}.contains(candidate.length)) {
    return candidate.padLeft(14, '0');
  }
  return candidate.replaceAll(RegExp(r'\s+'), '');
}

""",
)

replace_section(
    resolution,
    "double _weightedEditSimilarity(String left, String right) {",
    "double _ocrSubstitutionCost(String a, String b) {",
    r"""double _weightedEditSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  if (left.length > 80) left = left.substring(0, 80);
  if (right.length > 80) right = right.substring(0, 80);
  var previousPrevious = List<double>.generate(
    right.length + 1,
    (index) => index * .82,
  );
  var previous = List<double>.from(previousPrevious);
  for (var i = 0; i < left.length; i++) {
    final current = List<double>.filled(right.length + 1, 0)
      ..[0] = (i + 1) * .82;
    for (var j = 0; j < right.length; j++) {
      final substitution =
          previous[j] + _ocrSubstitutionCost(left[i], right[j]);
      final deletion = previous[j + 1] + .82;
      final insertion = current[j] + .82;
      var best = min(substitution, min(deletion, insertion));
      if (i > 0 &&
          j > 0 &&
          left[i] == right[j - 1] &&
          left[i - 1] == right[j]) {
        best = min(best, previousPrevious[j - 1] + .44);
      }
      current[j + 1] = best;
    }
    previousPrevious = previous;
    previous = current;
  }
  final scale = max(left.length, right.length).toDouble();
  return (1 - previous.last / scale).clamp(0, 1).toDouble();
}

""",
)

scan = "lib/services/scan_service.dart"
replace_once(
    scan,
    "import '../domain/gs1_healthcare.dart';\nimport '../domain/medicine_understanding.dart';",
    "import '../domain/medicine_understanding.dart';\nimport '../domain/regulatory_medicine_code.dart';",
)
replace_once(
    scan,
    "  final _barcodes = BarcodeScanner();",
    """  final _barcodes = BarcodeScanner(
    formats: const <BarcodeFormat>[
      BarcodeFormat.dataMatrix,
      BarcodeFormat.qrCode,
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.code128,
      BarcodeFormat.upca,
      BarcodeFormat.upce,
      BarcodeFormat.itf,
    ],
  );""",
)
replace_once(
    scan,
    """    final gs1 = parseGs1HealthcareBarcode(raw);
    if (gs1 != null && gs1.gtin.isNotEmpty) values.add(gs1.gtin);""",
    """    final structured = parseRegulatoryMedicineCode(raw);
    if (structured != null && structured.gtin.isNotEmpty) {
      values.add(structured.gtin);
    }""",
)
replace_section(
    scan,
    "int _barcodeScore(String value) {",
    "bool _validGtin(String digits) {",
    r"""int _barcodeScore(String value) {
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits == value && const {8, 12, 13, 14}.contains(digits.length)) {
    return _validGtin(digits) ? 6 : 3;
  }
  final structured = parseRegulatoryMedicineCode(value);
  if (structured != null && structured.gtin.isNotEmpty) return 5;
  if (digits == value && digits.length >= 6) return 3;
  if (structured != null && structured.hasTraceability) return 2;
  return 1;
}

""",
)

print("Level 6 source surgery applied successfully.")
