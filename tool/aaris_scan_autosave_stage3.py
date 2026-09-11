from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    print(f"[{label}] anchor count={count}")
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor in {path}, found {count}")
    file.write_text(text.replace(old, new, 1))


# Replace stale manual-only copy at its source.
replace_once(
    "lib/ui/import_screen.dart",
    """                if (_localBrainScanActive)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'Aaris Brain · raw OCR was handed to the active Local AI on-device before this preview. Confirmed fields still require your tap before inventory changes.',
                      style: TextStyle(
                        color: primary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
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
""",
    "brain-banner",
)

replace_once(
    "lib/ui/import_screen.dart",
    """                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'OCR text stays separate from your personal note. Every auto-filled fact remains review evidence until you explicitly save a reviewed action.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ),
""",
    """                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    widget.autoSaveReadyDrafts
                        ? 'OCR text stays separate from your personal note. Automatic save is allowed only after Local AI source verification plus deterministic duplicate, lot, chronology, confidence and revision checks.'
                        : 'OCR text stays separate from your personal note. Every auto-filled fact remains review evidence until you explicitly save a reviewed action.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ),
""",
    "review-footer",
)

replace_once(
    "lib/ui/import_screen.dart",
    "          detail: 'Barcode and packaging text together.',",
    "          detail: 'Capture once · Local AI verifies · safe scans can save automatically.',",
    "scan-action-copy",
)

replace_once(
    "lib/ui/scanner_screen.dart",
    """                                widget.onCaptureQueued != null
                                    ? 'Keep capturing. Processing continues in the saved inbox.'
                                    : 'Check the result, then tap Use scan.',
""",
    """                                widget.onCaptureQueued != null
                                    ? 'Keep capturing. Processing continues in the saved inbox.'
                                    : widget.autoSubmit
                                    ? 'Capture once. OCR will hand off automatically to Aaris Brain.'
                                    : 'Check the result, then tap Use scan.',
""",
    "scanner-status-copy",
)

replace_once(
    "lib/ui/scanner_screen.dart",
    """                            _camera == null
                                ? 'Retry camera'
                                : _capturing
                                ? 'Reading…'
                                : 'Capture text',
""",
    """                            _camera == null
                                ? 'Retry camera'
                                : _capturing
                                ? 'Reading…'
                                : widget.autoSubmit
                                ? 'Capture & automate'
                                : 'Capture text',
""",
    "scanner-capture-copy",
)

replace_once(
    "lib/services/local_ai_service_io.dart",
    "      _status = 'AI scan preview ready · confirm before adding';",
    "      _status = 'AI scan evidence verified · deterministic save gate deciding next step';",
    "local-ai-status",
)
