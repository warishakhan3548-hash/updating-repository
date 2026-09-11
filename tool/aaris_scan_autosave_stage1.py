from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    print(f"[{label}] anchor count={count}")
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor in {path}, found {count}")
    file.write_text(text.replace(old, new, 1))


# Replace the original human-only contract instead of layering a contradictory
# override on top of it.
replace_once(
    "lib/domain/medicine_scan_commit.dart",
    """/// AI/OCR may propose identity facts, but only the human-visible preview can
/// authorize creation. Existing-stock ambiguity, weak lot identity and invalid
/// chronology remain fail-closed. The controller's revision/CAS boundary is the
/// final authority at commit time.
""",
    """/// AI/OCR may propose identity facts, but deterministic commit policy alone
/// authorizes creation. Human review remains the fail-closed fallback whenever
/// evidence, lot identity or chronology is weak. The controller's revision/CAS
/// boundary is the final authority at commit time.
""",
    "commit-contract",
)

quick_tail = """  String get actionLabel =>
      isNewBatch ? 'Confirm & add new batch' : 'Confirm & add';
}
"""
auto_type = """

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
"""
replace_once(
    "lib/domain/medicine_scan_commit.dart",
    quick_tail,
    quick_tail + auto_type,
    "auto-decision-type",
)

auto_function = """ScanAutoSaveDecision scanAutoSaveDecision(
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

"""
replace_once(
    "lib/domain/medicine_scan_commit.dart",
    "bool _hasTrustedBatchAnchor(MedicineScanDraft draft) {",
    auto_function + "bool _hasTrustedBatchAnchor(MedicineScanDraft draft) {",
    "auto-decision-function",
)

# Capture is the final explicit scanner action. ScannerScreen's existing
# autoSubmit path returns the freshly recognized still frame automatically,
# removing the old second "Use scan" tap.
old_scan = """  Future<void> _scan() async {
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (result == null || !mounted) return;
    await _openInbox(
      result.evidence.isNotEmpty
          ? result.evidence
          : <ScanEvidence>[
              ScanEvidence(
                barcode: result.barcode,
                text: result.text,
                source: 'Live camera',
              ),
            ],
    );
  }
"""
new_scan = """  Future<void> _scan() async {
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(
        builder: (_) => const ScannerScreen(autoSubmit: true),
      ),
    );
    if (result == null || !mounted) return;
    await _openInbox(
      result.evidence.isNotEmpty
          ? result.evidence
          : <ScanEvidence>[
              ScanEvidence(
                barcode: result.barcode,
                text: result.text,
                source: 'Live camera',
              ),
            ],
      autoSaveReadyDrafts: true,
    );
  }
"""
replace_once("lib/ui/import_screen.dart", old_scan, new_scan, "direct-scan-route")

old_open = """  Future<void> _openInbox(List<ScanEvidence> evidence) async {
    if (evidence.every(
      (item) => item.barcode.isEmpty && item.text.trim().isEmpty,
    )) {
      throw const FormatException('No barcode or medicine text was captured.');
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ImportInboxScreen(
          controller: widget.controller,
          evidence: evidence,
        ),
      ),
    );
  }
"""
new_open = """  Future<void> _openInbox(
    List<ScanEvidence> evidence, {
    bool autoSaveReadyDrafts = false,
  }) async {
    if (evidence.every(
      (item) => item.barcode.isEmpty && item.text.trim().isEmpty,
    )) {
      throw const FormatException('No barcode or medicine text was captured.');
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ImportInboxScreen(
          controller: widget.controller,
          evidence: evidence,
          autoSaveReadyDrafts: autoSaveReadyDrafts,
        ),
      ),
    );
  }
"""
replace_once("lib/ui/import_screen.dart", old_open, new_open, "inbox-route-option")
