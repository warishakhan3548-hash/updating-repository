from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f"Expected patch anchor not found: {path}")
    file.write_text(text.replace(old, new, 1))


replace(
    "lib/domain/medicine_resolution_v2.dart",
    """  final catalogueKnowledge = catalogue
      .map((value) => value.knowledgeEntry)
      .take(maxCanonicalMedicineCandidates)
      .toList(growable: false);
  final localBudget = max(
    0,
    maxMedicineKnowledgeEntries - catalogueKnowledge.length,
  );
  final mergedKnowledge = <MedicineKnowledgeEntry>[
    ...catalogueKnowledge,
    ...localKnowledge.take(localBudget),
  ];
  final baseMessage = <String, Object?>{
    ...message,
    'knowledge': mergedKnowledge
        .take(maxMedicineKnowledgeEntries)
        .map((value) => value.toMessage())
        .toList(growable: false),
  };
""",
    """  // Preserve the physical pack's observed fields before product resolution.
  // Canonical catalogue facts must never enter the field-by-field extractor,
  // otherwise a candidate can rewrite contradictory OCR (for example 500 mg)
  // to its own canonical strength (650 mg) before the product-level conflict
  // engine has a chance to reject the impossible hybrid. Shop-reviewed local
  // knowledge remains safe recognition memory; Tier-2 catalogue data is used
  // only by the coherent ProductHypothesis resolver below.
  final baseMessage = <String, Object?>{
    ...message,
    'knowledge': localKnowledge
        .take(maxMedicineKnowledgeEntries)
        .map((value) => value.toMessage())
        .toList(growable: false),
  };
""",
)

replace(
    "lib/services/local_ai_runtime.dart",
    """  Future<void> _disposeTransport(
    StreamController<LlamaCommand>? commands,
    StreamSubscription<LlamaResponse>? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await commands?.close();
    } catch (_) {}
  }
""",
    """  Future<void> _disposeTransport(
    StreamController<LlamaCommand>? commands,
    StreamSubscription<LlamaResponse>? subscription,
  ) async {
    // Start both shutdown operations before awaiting either. Some async-generator
    // transports cannot finish subscription cancellation until their command
    // stream closes; awaiting cancel first therefore creates a circular wait.
    Future<void>? cancelFuture;
    Future<void>? closeFuture;
    try {
      cancelFuture = subscription?.cancel();
    } catch (_) {}
    try {
      closeFuture = commands?.close();
    } catch (_) {}
    if (cancelFuture != null) {
      try {
        await cancelFuture;
      } catch (_) {}
    }
    if (closeFuture != null) {
      try {
        await closeFuture;
      } catch (_) {}
    }
  }
""",
)

replace(
    "tool/check_local_ai.dart",
    """  check(
    corrected.field('salt').conflicted && corrected.needsReview,
    'New labels need review',
  );
""",
    """  check(
    !corrected.field('salt').conflicted &&
        corrected.field('salt').confidence >= .88,
    'Exact evidence can promote an empty priority identity field',
  );
""",
)

replace(
    "test/fefo_automation_test.dart",
    """    expect(plan.complete, isTrue);
    expect(plan.requiresExpiryVerification, isTrue);
    expect(plan.allocations.map((item) => item.stockId), [
      'dated',
      'unknown-exp',
    ]);
""",
    """    expect(plan.complete, isFalse);
    expect(plan.blockedByUnknownExpiry, isTrue);
    expect(plan.requiresExpiryVerification, isTrue);
    expect(plan.plannedQuantity, 0);
    expect(plan.allocations, isEmpty);
    expect(plan.unknownExpiryStockIds, ['unknown-exp']);
""",
)

Path("tool/.resolver_v2_ci_fix_marker").unlink(missing_ok=True)
Path("tool/resolver_v2_autofix.py").unlink(missing_ok=True)
Path(".github/workflows/resolver_v2_autofix.yml").unlink(missing_ok=True)
