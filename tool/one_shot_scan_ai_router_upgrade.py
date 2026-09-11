from pathlib import Path
import re


def read(path: str) -> str:
    return Path(path).read_text(encoding='utf-8')


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding='utf-8')


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one literal anchor, found {count}')
    write(path, text.replace(old, new, 1))


def replace_count(path: str, old: str, new: str, expected: int) -> None:
    text = read(path)
    count = text.count(old)
    if count != expected:
        raise SystemExit(f'{path}: expected {expected} literal anchors, found {count}')
    write(path, text.replace(old, new))


def sub_once(path: str, pattern: str, replacement: str) -> None:
    text = read(path)
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one regex anchor, found {count}')
    write(path, updated)


commit_path = 'lib/domain/medicine_scan_commit.dart'
replace_once(
    commit_path,
    """/// Stronger machine-commit gate for the direct camera automation path.
///
/// Local AI is an evidence resolver, never an inventory writer. Automatic
/// persistence requires a scan-verified on-device model to have reviewed this
/// exact OCR draft, plus all pre-existing deterministic quick-add invariants.
class ScanAutoSaveDecision {""",
    """enum ScanAutoSaveVerifier { localAi, cloudAi }

String scanAutoSaveVerifierLabel(ScanAutoSaveVerifier verifier) => switch (verifier) {
  ScanAutoSaveVerifier.localAi => 'Local AI',
  ScanAutoSaveVerifier.cloudAi => 'Cloud AI',
};

/// Stronger machine-commit gate for the direct camera automation path.
///
/// AI is an evidence resolver, never an inventory writer. Automatic persistence
/// requires this exact OCR draft to have crossed one source-verified AI route
/// plus all pre-existing deterministic quick-add invariants. Deterministic OCR
/// still auto-fills the preview when no AI route exists, but cannot grant itself
/// unattended inventory-write authority.
class ScanAutoSaveDecision {""",
)

replace_once(
    commit_path,
    """ScanAutoSaveDecision scanAutoSaveDecision(
  MedicineScanDraft draft,
  IntakeResolution resolution, {
  required bool localAiVerified,
}) {
  if (!localAiVerified) {
    return const ScanAutoSaveDecision.blocked(
      'A scan-verified Local AI did not verify this exact OCR draft. Review it before saving.',
    );
  }
""",
    """ScanAutoSaveDecision scanAutoSaveDecision(
  MedicineScanDraft draft,
  IntakeResolution resolution, {
  required ScanAutoSaveVerifier? verifier,
}) {
  if (verifier == null) {
    return const ScanAutoSaveDecision.blocked(
      'No source-verified AI route verified this exact OCR draft. The smart on-device extractor filled what it could; review before saving.',
    );
  }
""",
)

cloud_path = 'lib/services/cloud_scan_ai_service.dart'
replace_once(
    cloud_path,
    """/// Explicit cloud-only medicine-pack refinement.
///
/// This service never receives an inventory export and never writes inventory.
/// It sends only the bounded OCR handoff for one deterministic medicine draft,
/// then runs the same quote/evidence validator used by Local AI before returning
/// a preview candidate. The caller still owns the existing Confirm/Add boundary.
/// One instance belongs to one review screen, so cancellation cannot cross
/// navigation sessions.
""",
    """/// Privacy-bounded cloud medicine-pack refinement.
///
/// This service never receives an inventory export and never writes inventory.
/// It sends only the bounded OCR handoff for one deterministic medicine draft,
/// then runs the same quote/evidence validator used by Local AI before returning
/// a preview candidate. A direct camera flow may pass that validated candidate
/// through the authoritative machine-commit gate; all other callers keep the
/// existing review/Confirm boundary. One instance belongs to one review session,
/// so cancellation cannot cross navigation sessions.
""",
)

ui_path = 'lib/ui/import_screen.dart'
replace_once(
    ui_path,
    """import '../services/backup_service.dart';
import '../services/local_ai_service.dart';
""",
    """import '../services/ai_service.dart';
import '../services/backup_service.dart';
import '../services/cloud_scan_ai_service.dart';
import '../services/local_ai_service.dart';
""",
)

replace_once(
    ui_path,
    """          detail: 'Capture once · Local AI verifies · safe scans can save automatically.',
""",
    """          detail: 'Capture once · Local AI first, cloud AI when configured, smart on-device fallback · verified scans can save automatically.',
""",
)

replace_once(
    ui_path,
    """  final _semanticCache = <String, MedicineScanDraft>{};
  String _semanticWarning = '';
  bool _localBrainScanActive = false;
  int? _savingDraftIndex;
""",
    """  final _semanticCache = <String, MedicineScanDraft>{};
  final _cloudScan = CloudScanAiService();
  String _semanticWarning = '';
  String _scanReasoningRoute = '';
  bool _localBrainScanActive = false;
  bool _cloudBrainScanActive = false;
  int? _savingDraftIndex;
""",
)

replace_once(
    ui_path,
    """  void dispose() {
    ++_generation;
    widget.controller.removeListener(_inventoryChanged);
    super.dispose();
  }
""",
    """  void dispose() {
    ++_generation;
    _cloudScan.cancel();
    widget.controller.removeListener(_inventoryChanged);
    super.dispose();
  }
""",
)

replace_once(
    ui_path,
    """      _semanticWarning = '';
      _localBrainScanActive = false;
    });
""",
    """      _semanticWarning = '';
      _scanReasoningRoute = '';
      _localBrainScanActive = false;
      _cloudBrainScanActive = false;
    });
""",
)

sub_once(
    ui_path,
    r"""    try \{
      final knowledge = medicineKnowledgeFromRecords\(widget\.controller\.records\);
.*?      var localBrainUsed = false;
      var localBrainAutoSaveVerified = false;
""",
    """    try {
      final local = LocalAiService.instance;
      String? scanModelId;
      AiConfiguration? cloudConfig;

      // Route ownership is resolved BEFORE deterministic extraction. When the
      // direct camera is using cloud AI, local Medicine Database identity memory
      // is deliberately excluded from the provider-bound draft so only bounded
      // evidence from this scan can leave the device.
      if (widget.preparedDrafts == null) {
        try {
          final brainEnabled = await LocalBrainRoutePolicy.enabled();
          if (!mounted || generation != _generation) return;
          if (brainEnabled) {
            scanModelId = await LocalBrainRoutePolicy.captureModelId(local);
            if (!mounted || generation != _generation) return;
            if (scanModelId == null) {
              _semanticWarning =
                  local.hasSelection && local.scannerEnabled && !local.scanReady
                  ? 'Aaris Brain is enabled, but the selected Local AI is not Ready for scan review yet. Deterministic on-device extraction is being used.'
                  : 'Aaris Brain is enabled, but no scan-ready Local AI route is available right now. Deterministic on-device extraction is being used; cloud fallback stays off while Local Brain owns the route.';
            }
          } else if (widget.autoSaveReadyDrafts) {
            try {
              cloudConfig = await _cloudScan.requireConfiguration();
              if (!mounted || generation != _generation) return;
              _scanReasoningRoute = _cloudScan.routeLabel(cloudConfig);
            } catch (_) {
              cloudConfig = null;
            }
          }
        } catch (_) {
          if (!mounted || generation != _generation) return;
          scanModelId = null;
          cloudConfig = null;
          _semanticWarning =
              'AI route state could not be loaded for this scan. Smart deterministic on-device extraction is being used; nothing was sent externally.';
        }
      }

      final knowledge = cloudConfig == null
          ? medicineKnowledgeFromRecords(widget.controller.records)
          : const <MedicineKnowledgeEntry>[];
      final payload = widget.preparedDrafts != null
          ? MedicineUnderstandingResult(drafts: widget.preparedDrafts!)
                .toMessage()
          : await compute(understandMedicineEvidenceMessage, <String, Object?>{
              'evidence': widget.evidence
                  .map((item) => item.toMessage())
                  .toList(growable: false),
              'knowledge': knowledge
                  .map((entry) => entry.toMessage())
                  .toList(growable: false),
            });
      if (!mounted || generation != _generation) return;
      final understanding = MedicineUnderstandingResult.fromMessage(payload);
      final reviews = <_ImportDraftReview>[];

      var localBrainUsed = false;
      var cloudBrainUsed = false;
""",
)

replace_once(
    ui_path,
    """        var draft = original;
        final leasedModelId = scanModelId;
""",
    """        var draft = original;
        ScanAutoSaveVerifier? autoSaveVerifier;
        final leasedModelId = scanModelId;
""",
)

replace_once(
    ui_path,
    """                  localBrainUsed = true;
                  localBrainAutoSaveVerified = local.isModelScanVerified(
                    routedModelId,
                  );
                  scanModelId = routedModelId;
""",
    """                  localBrainUsed = true;
                  if (local.isModelScanVerified(routedModelId)) {
                    autoSaveVerifier = ScanAutoSaveVerifier.localAi;
                  }
                  scanModelId = routedModelId;
""",
)

replace_once(
    ui_path,
    """          } catch (_) {
            _semanticWarning = 'Local AI could not safely finish this OCR handoff. Original deterministic OCR drafts were retained; nothing was sent to an external AI.';
          }
        }
        if (!mounted || generation != _generation) return;
""",
    """          } catch (_) {
            _semanticWarning = 'Local AI could not safely finish this OCR handoff. Original deterministic OCR drafts were retained; nothing was sent to an external AI.';
          }
        } else if (cloudConfig != null) {
          try {
            draft = await _cloudScan.refine(cloudConfig, original);
            if (!mounted || generation != _generation) return;
            cloudBrainUsed = true;
            autoSaveVerifier = ScanAutoSaveVerifier.cloudAi;
          } catch (error) {
            final detail = error
                .toString()
                .replaceFirst(
                  RegExp(r'^(Exception|FormatException|Bad state|StateError):\\s*'),
                  '',
                )
                .trim();
            _semanticWarning =
                'Cloud AI could not safely finish this OCR handoff. Smart deterministic on-device extraction was retained and nothing was auto-saved. $detail';
          }
        }
        if (!mounted || generation != _generation) return;
""",
)

replace_once(
    ui_path,
    """          _ImportDraftReview(
            draft: draft,
            hits: hits.take(6).toList(growable: false),
            resolution: _resolve(draft),
          ),
""",
    """          _ImportDraftReview(
            draft: draft,
            hits: hits.take(6).toList(growable: false),
            resolution: _resolve(draft),
            autoSaveVerifier: autoSaveVerifier,
          ),
""",
)

replace_once(
    ui_path,
    """          _localBrainScanActive = localBrainUsed;
          _loading = false;
""",
    """          _localBrainScanActive = localBrainUsed;
          _cloudBrainScanActive = cloudBrainUsed;
          _loading = false;
""",
)

replace_once(
    ui_path,
    """            _attemptScannerAutoSave(
              generation,
              reviews.single,
              localBrainVerified: localBrainAutoSaveVerified,
            ),
""",
    """            _attemptScannerAutoSave(
              generation,
              reviews.single,
            ),
""",
)

replace_once(
    ui_path,
    """  Future<void> _attemptScannerAutoSave(
    int preparedGeneration,
    _ImportDraftReview review, {
    required bool localBrainVerified,
  }) async {
""",
    """  Future<void> _attemptScannerAutoSave(
    int preparedGeneration,
    _ImportDraftReview review,
  ) async {
""",
)

replace_count(
    ui_path,
    """      localAiVerified: localBrainVerified,
""",
    """      verifier: review.autoSaveVerifier,
""",
    2,
)

replace_once(
    ui_path,
    """                : '${medicine.title} verified by Local AI and auto-saved.',
""",
    """                : '${medicine.title} verified by ${scanAutoSaveVerifierLabel(review.autoSaveVerifier!)} and auto-saved.',
""",
)

replace_once(
    ui_path,
    """                        'LOCAL REVIEW',
""",
    """                        'SCAN REVIEW',
""",
)

sub_once(
    ui_path,
    r"""                if \(_localBrainScanActive\)
                  Padding\(
.*?                if \(_error\.isNotEmpty\)
""",
    """                if (_localBrainScanActive)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      widget.autoSaveReadyDrafts
                          ? 'Aaris Brain · raw OCR was handed to the active Local AI on-device. One scan-verified, unambiguous medicine can save automatically; uncertainty and duplicates stop here for review.'
                          : 'Aaris Brain · raw OCR was handed to the active Local AI on-device before this preview. Confirmed fields still require your tap before inventory changes.',
                      style: const TextStyle(
                        color: primary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (_cloudBrainScanActive)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _scanReasoningRoute.isEmpty
                          ? 'Cloud AI · only bounded OCR evidence from this scan was sent. Returned medicine fields were checked against the captured source before this preview.'
                          : 'Cloud AI · $_scanReasoningRoute · only bounded OCR evidence from this scan was sent. Returned medicine fields were checked against the captured source before this preview.',
                      style: const TextStyle(
                        color: primary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (widget.autoSaveReadyDrafts &&
                    !_localBrainScanActive &&
                    !_cloudBrainScanActive)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'Aaris Smart Extractor · on-device OCR + pharmacy NER/rules auto-filled supported medicine fields. No source-verified AI route completed this scan, so the preview stays review-first instead of writing uncertain OCR directly to stock.',
                      style: TextStyle(
                        color: amber,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (_error.isNotEmpty)
""",
)

replace_once(
    ui_path,
    """                        ? 'OCR text stays separate from your personal note. Automatic save is allowed only after Local AI source verification plus deterministic duplicate, lot, chronology, confidence and revision checks.'
""",
    """                        ? 'OCR text stays separate from your personal note. Automatic save is allowed only after source-verified Local AI or configured cloud AI plus deterministic duplicate, lot, chronology, confidence and revision checks. With no AI route, the smart on-device extractor still auto-fills the preview for review.'
""",
)

replace_once(
    ui_path,
    """  const _ImportDraftReview({
    required this.draft,
    required this.hits,
    required this.resolution,
  });

  final MedicineScanDraft draft;
  final List<SearchHit> hits;
  final IntakeResolution resolution;
""",
    """  const _ImportDraftReview({
    required this.draft,
    required this.hits,
    required this.resolution,
    required this.autoSaveVerifier,
  });

  final MedicineScanDraft draft;
  final List<SearchHit> hits;
  final IntakeResolution resolution;
  final ScanAutoSaveVerifier? autoSaveVerifier;
""",
)

test_path = 'test/scan_auto_save_decision_test.dart'
replace_count(
    test_path,
    'localAiVerified: true',
    'verifier: ScanAutoSaveVerifier.localAi',
    5,
)
replace_count(
    test_path,
    'localAiVerified: false',
    'verifier: null',
    1,
)
replace_once(
    test_path,
    """  test('new stock needs scan-verified Local AI before auto-save', () {
""",
    """  test('new stock needs source-verified AI before auto-save', () {
""",
)
replace_once(
    test_path,
    """    expect(
      scanAutoSaveDecision(
        draft,
        resolution,
        verifier: ScanAutoSaveVerifier.localAi,
      ).allowed,
      isTrue,
    );
  });
""",
    """    expect(
      scanAutoSaveDecision(
        draft,
        resolution,
        verifier: ScanAutoSaveVerifier.localAi,
      ).allowed,
      isTrue,
    );
    expect(
      scanAutoSaveDecision(
        draft,
        resolution,
        verifier: ScanAutoSaveVerifier.cloudAi,
      ).allowed,
      isTrue,
    );
  });
""",
)

doc = Path('docs/SCAN_AI_ROUTING_2026_09_11.md')
doc.write_text("""# Aaris Pharmacy scan → AI → inventory map

## Dependency tree

`ScannerScreen`
→ `MedicineVisionService`
→ ML Kit Latin + Devanagari OCR + barcode
→ `MedicineFrameEvidence`
→ `understandMedicineEvidenceMessage`
→ deterministic pharmacy entity extraction (`MedicineScanDraft`)
→ route policy
  - Local Brain ON + scan-ready model → `LocalAiService.understand`
  - Local Brain OFF + valid configured API → `CloudScanAiService.refine`
  - neither route → deterministic on-device extractor only
→ exact-source validation (`validateLocalScan`)
→ duplicate / lot resolution (`resolveIntakeDraft`)
→ machine-save gate (`scanAutoSaveDecision`)
→ normalized `Medicine` (`medicineFromConfirmedScan`)
→ `PharmacyController.save`
→ revision-bound `InventoryMutation`
→ storage compare-and-swap commit.

## UI/state map

Capture → OCR evidence → route resolution → structured fields populate the scan preview.
A source-verified Local or Cloud AI result can proceed to automatic save only when
Brand + Salt + Strength + Form, overall confidence, batch/date integrity, duplicate
resolution, and live inventory revision all pass. Any ambiguity stops at review.

When no AI route is available, the existing deterministic pharmacy parser acts as
the offline NER/entity extractor and auto-fills supported fields, but it does not
grant itself unattended inventory-write authority.

## Privacy and routing invariants

1. Local Brain has priority when its owner switch is ON. A Local AI failure never
   silently leaks the scan to cloud.
2. Cloud routing is considered only for the direct camera automation path when
   Local Brain is OFF and a valid API configuration already exists.
3. Before cloud handoff, local Medicine Database identity memory is removed from
   the provider-bound deterministic draft. Only bounded OCR evidence and
   deterministic candidates derived from that scan are sent.
4. Local and Cloud model output are proposals. `validateLocalScan` requires
   source-grounded evidence before fields can influence the preview.
5. AI services never write inventory. The deterministic domain gate and
   `PharmacyController` remain the only write authority.
6. Exact existing lots, ambiguous products, weak/conflicting fields, invalid
   chronology, or stale revisions fail closed to review.
""", encoding='utf-8')
