import 'dart:math';

import '../domain/local_ai_protocol.dart';
import '../domain/local_context_budget.dart';
import '../domain/local_scan_handoff.dart';
import '../domain/medicine_understanding.dart';

/// A scan is already a fresh prompt, never a continuing chat. Re-budget only an
/// exact native admission failure (before inference), under the existing lease.
/// Malformed JSON, cancellation and transport/model failures are not retried.
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
  var handoff = LocalScanHandoff.fromDraft(draft, sourceLimit: limit);
  LocalContextBudgetFailure? lastBudgetFailure;
  for (var attempt = 0; attempt < 4; attempt++) {
    checkCurrent();
    if (handoff.sourceCharacters == 0) break;
    onAttempt?.call(handoff, attempt);
    checkCurrent();
    try {
      final raw = await generate(handoff, budget);
      checkCurrent();
      return validateLocalScan(draft, localJsonObject(raw), sourceLimit: limit);
    } on LocalContextBudgetFailure catch (error) {
      checkCurrent();
      lastBudgetFailure = error;
      final available = error.contextTokens - error.inputTokens - 32;
      if (available >= min(outputTokens, 256) && available < budget) {
        budget = available;
        continue;
      }
      // Character selection is only a coarse reduction. The next native
      // admission check remains authoritative for this model's tokenizer.
      LocalScanHandoff? smaller;
      while (limit > 256) {
        limit = max(256, limit ~/ 2);
        final candidate = LocalScanHandoff.fromDraft(draft, sourceLimit: limit);
        // A sparse/short label can be unchanged at several budget steps. Skip
        // those steps in memory; do not fail early or re-run identical prompts.
        if (candidate.userPayload.length < handoff.userPayload.length) {
          smaller = candidate;
          break;
        }
      }
      if (smaller == null) break;
      handoff = smaller;
    }
  }
  throw FormatException(
    'This scan cannot fit a safe evidence/answer budget${lastBudgetFailure == null ? '' : ' in the loaded ${lastBudgetFailure.contextTokens}-token context'}. Capture a closer crop of one pack. The model remains available and the original offline draft is retained for review.',
  );
}
