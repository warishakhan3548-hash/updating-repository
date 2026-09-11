from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    print(f"[{label}] anchor count={count}")
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor in {path}, found {count}")
    file.write_text(text.replace(old, new, 1))


replace_once(
    "lib/ui/import_screen.dart",
    """    this.preparedDrafts,
  });

  final PharmacyController controller;
  final List<ScanEvidence> evidence;
  final List<MedicineScanDraft>? preparedDrafts;
""",
    """    this.preparedDrafts,
    this.autoSaveReadyDrafts = false,
  });

  final PharmacyController controller;
  final List<ScanEvidence> evidence;
  final List<MedicineScanDraft>? preparedDrafts;

  /// True only for the direct camera scanner. Photo/video/text and prepared
  /// batch imports preserve explicit review semantics.
  final bool autoSaveReadyDrafts;
""",
    "inbox-constructor",
)

replace_once(
    "lib/ui/import_screen.dart",
    """  bool _localBrainScanActive = false;
  int? _savingDraftIndex;
""",
    """  bool _localBrainScanActive = false;
  int? _savingDraftIndex;
  bool _autoSaveAttempted = false;
""",
    "autosave-state",
)

replace_once(
    "lib/ui/import_screen.dart",
    "      var localBrainUsed = false;\n",
    "      var localBrainUsed = false;\n      var localBrainAutoSaveVerified = false;\n",
    "verification-state",
)

# AI result can unlock persistence only after route ownership is revalidated and
# that exact active model has passed the existing scan setup probe.
replace_once(
    "lib/ui/import_screen.dart",
    """                  draft = candidate;
                  _semanticCache[key] = candidate;
                  localBrainUsed = true;
                  scanModelId = routedModelId;
""",
    """                  draft = candidate;
                  _semanticCache[key] = candidate;
                  localBrainUsed = true;
                  localBrainAutoSaveVerified =
                      local.isModelScanVerified(routedModelId);
                  scanModelId = routedModelId;
""",
    "verification-proof",
)

old_finish = """      if (mounted && generation == _generation) {
        setState(() {
          _drafts = reviews;
          _ignoredFrames = understanding.ignoredFrames;
          _localBrainScanActive = localBrainUsed;
          _loading = false;
        });
      }
"""
new_finish = """      if (mounted && generation == _generation) {
        setState(() {
          _drafts = reviews;
          _ignoredFrames = understanding.ignoredFrames;
          _localBrainScanActive = localBrainUsed;
          _loading = false;
        });
        if (widget.autoSaveReadyDrafts &&
            reviews.length == 1 &&
            !_autoSaveAttempted) {
          unawaited(
            _attemptScannerAutoSave(
              generation,
              reviews.single,
              localBrainVerified: localBrainAutoSaveVerified,
            ),
          );
        }
      }
"""
replace_once("lib/ui/import_screen.dart", old_finish, new_finish, "autosave-dispatch")

auto_method = """  Future<void> _attemptScannerAutoSave(
    int preparedGeneration,
    _ImportDraftReview review, {
    required bool localBrainVerified,
  }) async {
    if (!widget.autoSaveReadyDrafts ||
        _autoSaveAttempted ||
        !mounted ||
        preparedGeneration != _generation) {
      return;
    }
    _autoSaveAttempted = true;

    var resolution = _resolve(review.draft);
    var decision = scanAutoSaveDecision(
      review.draft,
      resolution,
      localAiVerified: localBrainVerified,
    );
    if (!decision.allowed) {
      setState(() {
        _semanticWarning = 'Auto-save paused · ${decision.reason}';
      });
      return;
    }

    setState(() => _savingDraftIndex = 0);
    try {
      // Re-resolve against the live database immediately before CAS. Any lot,
      // duplicate or concurrent inventory change fails closed rather than
      // turning a probabilistic AI result into a second stock row.
      resolution = _resolve(review.draft);
      decision = scanAutoSaveDecision(
        review.draft,
        resolution,
        localAiVerified: localBrainVerified,
      );
      if (!decision.allowed) {
        throw StateError(
          decision.reason.isEmpty
              ? 'Inventory changed. Review this scan before saving.'
              : decision.reason,
        );
      }

      final expectedRevision = widget.controller.snapshot.revision;
      final medicine = medicineFromConfirmedScan(review.draft);
      await widget.controller.save(
        medicine,
        expectedRevision: expectedRevision,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            decision.isNewBatch
                ? '${medicine.title} auto-saved as a verified new batch.'
                : '${medicine.title} verified by Local AI and auto-saved.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _semanticWarning = 'Auto-save paused safely · $error';
        });
      }
    } finally {
      if (mounted && _savingDraftIndex == 0) {
        setState(() => _savingDraftIndex = null);
      }
    }
  }

"""
replace_once(
    "lib/ui/import_screen.dart",
    "  Future<void> _confirmAndAdd(\n",
    auto_method + "  Future<void> _confirmAndAdd(\n",
    "autosave-method",
)
