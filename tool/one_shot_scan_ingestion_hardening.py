from pathlib import Path
import re


def read(path: str) -> str:
    return Path(path).read_text(encoding='utf-8')


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding='utf-8')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)


def regex_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one regex match, found {count}')
    return updated


path = 'lib/ui/import_screen.dart'
text = read(path)

# The normal Add/Import inbox is an on-device/local-AI lane. Cloud scanning has
# its own explicit CloudScanReviewScreen and must never be selected merely because
# an API key is configured.
text = replace_once(text, "import '../services/ai_service.dart';\n", '', 'remove AiConfiguration import')
text = replace_once(text, "import '../services/cloud_scan_ai_service.dart';\n", '', 'remove implicit cloud scanner import')

# Make gallery photo and video imports share the same durable private-copy +
# SQLite checkpoint path. This removes the transient one-off photo OCR path.
text = regex_once(
    text,
    r"  Future<void> _photo\(\) async \{.*?\n  Future<void> _textFile\(\) async \{",
    """  Future<void> _photo() => _queueMedia('photo');

  Future<void> _video() => _queueMedia('video');

  Future<void> _queueMedia(String kind) async {
    if (_busy) return;
    if (kind != 'photo' && kind != 'video') {
      throw const FormatException('Choose a photo or video import.');
    }
    final generation = ++_generation;
    PickedImportSource? picked;
    setState(() {
      _busy = true;
      _cancelRequested = false;
    });
    try {
      final source = await _media.pick(kind == 'video' ? 'video' : 'image');
      picked = source;
      if (source == null || !mounted || generation != _generation) return;

      // Copy + durable job insert happen before this call returns. OCR and Local
      // AI may continue afterwards, but a process death cannot erase the chosen
      // source or its queue identity once the user sees it in the intake panel.
      final queue = MedicineIntakeService.instance;
      await queue.attach(
        () => widget.controller.records,
        revision: () => widget.controller.snapshot.revision,
      );
      if (!mounted || generation != _generation) return;
      await queue.addFile(source.path, kind: kind, title: source.name);
    } catch (error) {
      if (mounted && generation == _generation) showError(context, error);
    } finally {
      try {
        if (picked != null) await _media.cleanup([picked.path]);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelRequested = false;
        });
      }
    }
  }

  Future<void> _textFile() async {""",
    'unify gallery media into durable intake',
)

text = replace_once(text, "  int _done = 0;\n  int _total = 0;\n", '', 'remove transient import counters')
text = replace_once(
    text,
    "detail: 'Capture once · Local AI first, cloud AI when configured, smart on-device fallback · verified scans can save automatically.',",
    "detail: 'Capture once · on-device OCR · Local AI when enabled · smart deterministic fallback · verified local scans can save automatically.',",
    'plain scan privacy copy',
)
text = replace_once(
    text,
    "detail: 'Read an existing label or medicine-list photo.',",
    "detail: 'Saved first, then read locally in the resumable intake queue.',",
    'photo durability copy',
)
text = replace_once(
    text,
    "detail: 'Read medicine packs from a video on your phone.',",
    "detail: 'Saved first, then sampled locally in resumable video windows.',",
    'video durability copy',
)
text = regex_once(
    text,
    r"          LinearProgressIndicator\(value: _total == 0 \? null : _done / _total\),\n          const SizedBox\(height: 10\),\n          Text\(\n            _cancelRequested\n                \? 'Finishing the current local step and cleaning temporary files…'\n                : _total == 0\n                \? 'Preparing local import…'\n                : 'Reading frame \$_done of \$_total locally…',",
    """          const LinearProgressIndicator(),
          const SizedBox(height: 10),
          Text(
            _cancelRequested
                ? 'Finishing the current local step and cleaning temporary files…'
                : 'Preparing local import…',""",
    'remove obsolete transient progress model',
)

text = replace_once(
    text,
    "  final _semanticCache = <String, MedicineScanDraft>{};\n  final _cloudScan = CloudScanAiService();\n  String _semanticWarning = '';\n  String _scanReasoningRoute = '';\n  bool _localBrainScanActive = false;\n  bool _cloudBrainScanActive = false;\n",
    "  final _semanticCache = <String, MedicineScanDraft>{};\n  String _semanticWarning = '';\n  bool _localBrainScanActive = false;\n",
    'remove implicit cloud inbox state',
)
text = replace_once(text, "    _cloudScan.cancel();\n", '', 'remove implicit cloud transport disposal')
text = replace_once(
    text,
    "      _semanticWarning = '';\n      _scanReasoningRoute = '';\n      _localBrainScanActive = false;\n      _cloudBrainScanActive = false;\n",
    "      _semanticWarning = '';\n      _localBrainScanActive = false;\n",
    'reset local-only scan state',
)
text = replace_once(text, "      AiConfiguration? cloudConfig;\n", '', 'remove cloud route variable')

text = regex_once(
    text,
    r"\n      // Route ownership is resolved BEFORE deterministic extraction\..*?\n      final knowledge = cloudConfig == null\n          \? medicineKnowledgeFromRecords\(widget\.controller\.records\)\n          : const <MedicineKnowledgeEntry>\[\];",
    """
      // The normal ImportInbox is privacy-first and local by construction.
      // A configured cloud API is not scan consent. Only the separate
      // CloudScanReviewScreen, reached from the explicit "Scan with cloud AI"
      // choice, may send bounded OCR outside the device.
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
                  : 'Aaris Brain is enabled, but no scan-ready Local AI route is available right now. Deterministic on-device extraction is being used; no cloud fallback is allowed from this scan lane.';
            }
          }
        } catch (_) {
          if (!mounted || generation != _generation) return;
          scanModelId = null;
          _semanticWarning =
              'Local AI route state could not be loaded for this scan. Smart deterministic on-device extraction is being used; nothing was sent externally.';
        }
      }

      final knowledge = medicineKnowledgeFromRecords(widget.controller.records);""",
    'make normal inbox local-only',
)

text = replace_once(text, "      var localBrainUsed = false;\n      var cloudBrainUsed = false;\n", "      var localBrainUsed = false;\n", 'remove cloud usage state')
text = regex_once(
    text,
    r"\n        \} else if \(cloudConfig != null\) \{.*?\n        \}\n        if \(!mounted \|\| generation != _generation\) return;",
    "\n        }\n        if (!mounted || generation != _generation) return;",
    'remove implicit cloud refinement branch',
)
text = replace_once(text, "          _cloudBrainScanActive = cloudBrainUsed;\n", '', 'remove cloud result state')

text = regex_once(
    text,
    r"\n                if \(_cloudBrainScanActive\).*?\n                if \(widget\.autoSaveReadyDrafts &&\n                    !_localBrainScanActive &&\n                    !_cloudBrainScanActive\)",
    "\n                if (widget.autoSaveReadyDrafts &&\n                    !_localBrainScanActive)",
    'remove cloud scan review banner',
)
text = replace_once(
    text,
    "Automatic save is allowed only after source-verified Local AI or configured cloud AI plus deterministic duplicate, lot, chronology, confidence and revision checks. With no AI route, the smart on-device extractor still auto-fills the preview for review.",
    "Automatic save is allowed only after source-verified Local AI plus deterministic duplicate, lot, chronology, confidence and revision checks. With no Local AI route, the smart on-device extractor still auto-fills the preview for review; cloud use requires the separate explicit Cloud AI scan action.",
    'local-only autosave explanation',
)

# Hard fail if an accidental implicit cloud dependency survives in the normal inbox.
for forbidden in ('CloudScanAiService', 'AiConfiguration? cloudConfig', '_cloudBrainScanActive', '_scanReasoningRoute'):
    if forbidden in text:
        raise SystemExit(f'implicit cloud dependency still present in import_screen.dart: {forbidden}')
write(path, text)

# Update existing architecture docs so the code map and privacy/durability contract
# describe the executable behavior instead of contradicting it.
path = 'docs/SCAN_MEDIA_DEEP_AUDIT_2026_09_11.md'
text = read(path)
text = replace_once(
    text,
    "The immediate Upload photo path remains intentionally interactive: it runs the same `MedicineVisionService` OCR/barcode extraction and opens the same review inbox. It does not bypass validation or the authoritative controller save boundary.",
    "The Add / Import **Upload photo** path now enters the same durable intake lane as video: the picker staging file is copied into app-private storage and the SQLite job row is committed before the UI considers the import accepted. OCR and optional selected Local AI run afterwards, so process death/background interruption cannot erase an accepted photo. Review and the authoritative controller save boundary remain unchanged.",
    'update photo audit contract',
)
write(path, text)

path = 'docs/SCAN_AI_ROUTING_2026_09_11.md'
text = read(path)
text = replace_once(
    text,
    "  - Local Brain ON + scan-ready model → `LocalAiService.understand`\n  - Local Brain OFF + valid configured API → `CloudScanAiService.refine`\n  - neither route → deterministic on-device extractor only",
    "  - Local Brain ON + scan-ready model → `LocalAiService.understand`\n  - Local Brain OFF/unavailable → deterministic on-device extractor only\n  - explicit **Scan with cloud AI** action → separate `CloudScanReviewScreen` → `CloudScanAiService.refine`",
    'route tree explicit cloud consent',
)
text = replace_once(
    text,
    "2. Cloud routing is considered only for the direct camera automation path when\n   Local Brain is OFF and a valid API configuration already exists.",
    "2. Cloud routing is never inferred from a saved API configuration. It is entered\n   only after the owner explicitly chooses **Scan with cloud AI** for that capture.",
    'privacy invariant explicit cloud consent',
)
write(path, text)

# Add focused regression coverage. This is deliberately a source-level architecture
# contract because the boundary being protected is which UI lane owns an external
# transport; domain unit tests cannot detect an accidental import/wiring regression.
test_path = Path('test/scan_ingestion_privacy_contract_test.dart')
test_path.write_text("""import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal import inbox has no implicit cloud scan transport', () {
    final normal = File('lib/ui/import_screen.dart').readAsStringSync();
    final explicitCloud = File(
      'lib/ui/cloud_scan_review_screen.dart',
    ).readAsStringSync();
    final capture = File('lib/ui/medicine_capture.dart').readAsStringSync();

    expect(normal, isNot(contains('CloudScanAiService')));
    expect(normal, isNot(contains("../services/cloud_scan_ai_service.dart")));
    expect(explicitCloud, contains('CloudScanAiService'));
    expect(capture, contains('Scan with cloud AI'));
    expect(capture, contains('CloudScanReviewScreen'));
  });

  test('gallery photo and video both enter the durable intake queue', () {
    final source = File('lib/ui/import_screen.dart').readAsStringSync();

    expect(source, contains("Future<void> _photo() => _queueMedia('photo');"));
    expect(source, contains("Future<void> _video() => _queueMedia('video');"));
    expect(
      source,
      contains('await queue.addFile(source.path, kind: kind, title: source.name);'),
    );
    expect(source, isNot(contains('final vision = MedicineVisionService();')));
  });
}
""", encoding='utf-8')

Path('docs/SCAN_INGESTION_HARDENING_2026_09_11.md').write_text("""# Aaris Pharmacy — scan ingestion hardening (2026-09-11)

## Dependency tree

```text
Normal camera scan
  -> ScannerScreen live bounded evidence + captured still
  -> on-device OCR/barcode
  -> deterministic medicine understanding
  -> selected Local AI only when Aaris Brain is enabled
  -> source validation
  -> duplicate/lot/chronology gate
  -> verified local-AI auto-save OR review
  -> PharmacyController revision-bound save
  -> atomic SQLite inventory transaction

Explicit cloud scan
  -> owner chooses Scan with cloud AI
  -> on-device OCR/barcode
  -> CloudScanReviewScreen
  -> bounded scan-derived OCR only -> configured cloud AI
  -> source validation -> review -> revision-bound save

Gallery photo / video
  -> system picker staging file
  -> app-private copy
  -> durable intake SQLite job checkpoint
  -> photo OCR OR bounded video-window sampling
  -> deterministic resolver
  -> capture-bound Local AI when enabled
  -> durable review drafts
  -> pharmacist Confirm/Add
```

## Surgical fixes

### 1. Plain Scan can no longer infer cloud consent

The Add / Import `Scan medicine` route previously allowed a saved cloud API configuration to become an implicit OCR handoff whenever Local Brain was off. That contradicted the explicit cloud lane already exposed by `medicine_capture.dart` and the repository privacy invariant that configuration alone is not consent.

`ImportInboxScreen` is now local-only. Its cloud transport, cloud state and duplicated provider branch were removed. Cloud OCR exists only in `CloudScanReviewScreen`, reached after the owner explicitly chooses **Scan with cloud AI**.

### 2. Upload Photo is now crash-resumable

The standalone Upload Photo action previously performed transient OCR directly from the picker cache while Upload Video entered `MedicineIntakeService`. An accepted photo could therefore disappear if the process died between picker return and review.

Photo and video now share one `_queueMedia` path. `MedicineIntakeService.addFile` copies the source into private storage and commits the SQLite job before returning; OCR/Local-AI work can safely resume later. The picker staging file remains best-effort cleanup only.

## Invariants retained

- No scanner or AI owns an inventory database handle.
- Local AI output remains evidence-grounded proposal data.
- Normal scan/photo/video never fall through to cloud.
- Exact lot, duplicate, date/chronology and revision gates remain authoritative.
- Cloud scanning remains available as an explicit per-capture action.
- Photo/video queue capacity, private source ownership and worker barriers remain unchanged.
""", encoding='utf-8')

print('Aaris scan ingestion hardening applied successfully.')
