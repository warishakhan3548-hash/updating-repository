import 'dart:math';

import '../domain/local_ai_protocol.dart';
import '../domain/local_context_budget.dart';
import '../domain/local_scan_handoff.dart';
import '../domain/medicine_understanding.dart';

const double _machineCommitConfidenceFloor = .88;
const double _reviewOnlyConfidence = .879;

String _witnessText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _doseWitness(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

bool _quotedFieldWitness(
  MedicineScanDraft validated,
  Map<dynamic, dynamic> fields,
  String key,
) {
  final proposal = fields[key];
  if (proposal is! Map) return false;
  final value = proposal['value'];
  final quote = proposal['quote'];
  if (value is! String || quote is! String) return false;
  final cleanValue = _witnessText(value);
  final cleanQuote = _witnessText(quote);
  final acceptedValue = _witnessText(validated.field(key).value);
  if (cleanValue.isEmpty || acceptedValue != cleanValue) return false;
  return (' $cleanQuote ').contains(' $cleanValue ');
}

/// Machine commit authority is narrower than "the model returned valid JSON".
///
/// [validateLocalScan] already proves that every accepted quote came from this
/// bounded OCR source and that ingredient pairs are adjacent/printed safely.
/// This witness adds the final requirement for unattended save: the *current*
/// turn must have source-grounded brand + form plus a fully validated canonical
/// salt/strength ingredient set. Model setup/smoke-test success alone is never
/// sufficient authority for a particular medicine pack.
bool _hasAutoSaveIdentityWitness(
  MedicineScanDraft validated,
  Map<String, dynamic> answer,
) {
  final rawFields = answer['fields'];
  if (rawFields is! Map ||
      !_quotedFieldWitness(validated, rawFields, 'brand') ||
      !_quotedFieldWitness(validated, rawFields, 'form')) {
    return false;
  }

  final ingredients = answer['ingredients'];
  if (ingredients is! List || ingredients.isEmpty) return false;
  final salts = <String>[];
  final strengths = <String>[];
  for (final ingredient in ingredients) {
    if (ingredient is! Map) return false;
    final salt = ingredient['salt'];
    final strength = ingredient['strength'];
    if (salt is! String ||
        strength is! String ||
        salt.trim().isEmpty ||
        strength.trim().isEmpty) {
      return false;
    }
    salts.add(salt.trim());
    strengths.add(strength.trim());
  }

  return _witnessText(salts.join(' + ')) == _witnessText(validated.salt) &&
      _doseWitness(strengths.join(' + ')) ==
          _doseWitness(validated.strength);
}

/// Keeps a useful deterministic/AI-refined preview while making the existing
/// 0.88 machine-commit gate fail closed for a turn that did not prove all four
/// identity fields from this exact OCR source. Human Next/review remains usable
/// because the ordinary quick-add review floor is lower than this cap.
MedicineScanDraft _reviewOnly(MedicineScanDraft draft) {
  if (draft.overallConfidence < _machineCommitConfidenceFloor) return draft;
  return MedicineScanDraft(
    fields: draft.fields,
    rawText: draft.rawText,
    searchKeywords: draft.searchKeywords,
    frameSequences: draft.frameSequences,
    expiryMonthOnly: draft.expiryMonthOnly,
    mfgMonthOnly: draft.mfgMonthOnly,
    printedPackSize: draft.printedPackSize,
    printedMrp: draft.printedMrp,
    overallConfidence: min(draft.overallConfidence, _reviewOnlyConfidence),
  );
}

/// A scan is already a fresh prompt, never a continuing chat. Native context
/// admission is retried with a smaller evidence window. Empty/malformed model
/// output gets one bounded repair attempt. If the optional Local AI reviewer
/// cannot prove this pack's complete save identity, the best available draft is
/// retained for human review but is deliberately prevented from machine commit.
Future<MedicineScanDraft> runLocalScanTurn({
  required MedicineScanDraft draft,
  required int sourceLimit,
  required int outputTokens,
  required Future<String> Function(LocalScanHandoff handoff, int outputTokens)
  generate,
  required void Function() checkCurrent,
  void Function(LocalScanHandoff handoff, int attempt)? onAttempt,
}) async {
  if (outputTokens < 1 || outputTokens > 1000) {
    throw const FormatException('Invalid scan output budget.');
  }

  var limit = sourceLimit;
  var budget = outputTokens;
  var structuredFailures = 0;
  var handoff = LocalScanHandoff.fromDraft(draft, sourceLimit: limit);

  LocalScanHandoff? smallerEvidence() {
    while (limit > 256) {
      final nextLimit = max(256, limit ~/ 2);
      if (nextLimit == limit) break;
      limit = nextLimit;
      final candidate = LocalScanHandoff.fromDraft(draft, sourceLimit: limit);
      // Sparse/short labels can remain byte-identical through several nominal
      // limits. Skip those steps without spending another model generation.
      if (candidate.userPayload.length < handoff.userPayload.length) {
        return candidate;
      }
    }
    return null;
  }

  for (var attempt = 0; attempt < 4; attempt++) {
    checkCurrent();
    // Barcode-only or otherwise text-free deterministic drafts have nothing for
    // a text-only local model to verify. Preserve the draft but never grant a
    // model-verification machine-commit signal for evidence it did not inspect.
    if (handoff.sourceCharacters == 0) return _reviewOnly(draft);

    onAttempt?.call(handoff, attempt);
    checkCurrent();
    try {
      final raw = await generate(handoff, budget);
      checkCurrent();

      // Never feed an empty successful transport result into jsonDecode(). Tiny
      // GGUFs can emit EOS immediately and some chat-template parsers can also
      // temporarily withhold content. One smaller-evidence retry is useful; a
      // second empty/invalid answer proves this optional reviewer has no safe
      // machine-commit contribution for the current pack.
      if (raw.trim().isEmpty) {
        structuredFailures++;
        final smaller = structuredFailures < 2 ? smallerEvidence() : null;
        if (smaller != null) {
          handoff = smaller;
          continue;
        }
        return _reviewOnly(draft);
      }

      try {
        final answer = localJsonObject(raw);
        final validated = validateLocalScan(
          draft,
          answer,
          sourceLimit: limit,
        );
        return _hasAutoSaveIdentityWitness(validated, answer)
            ? validated
            : _reviewOnly(validated);
      } on FormatException {
        structuredFailures++;
        final smaller = structuredFailures < 2 ? smallerEvidence() : null;
        if (smaller != null) {
          handoff = smaller;
          continue;
        }
        // Fail closed to the evidence-backed deterministic result. Never repair
        // truncated JSON, invent missing braces, or trust malformed model prose.
        return _reviewOnly(draft);
      }
    } on LocalContextBudgetFailure catch (error) {
      checkCurrent();
      final available = error.contextTokens - error.inputTokens - 32;
      if (available >= min(outputTokens, 256) && available < budget) {
        budget = available;
        continue;
      }

      // Character selection is only a coarse reduction. The next native
      // admission check remains authoritative for this model's tokenizer.
      final smaller = smallerEvidence();
      if (smaller == null) return _reviewOnly(draft);
      handoff = smaller;
    }
  }

  // Local AI is an optional verifier, never the owner of the scanner's base
  // evidence. Exhausting its bounded repair/admission attempts keeps the
  // already-valid offline draft reviewable but cannot authorize machine save.
  return _reviewOnly(draft);
}
