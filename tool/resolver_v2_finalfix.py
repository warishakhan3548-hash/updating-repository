from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f"Expected patch anchor not found: {path}")
    file.write_text(text.replace(old, new, 1))


replace(
    "lib/domain/medicine_resolution_v2.dart",
    """    if (agrees) {
      channels++;
    } else if (draft.field('strength').confidence >= .78) {
      hardConflicts++;
    }
""",
    """    if (agrees) {
      channels++;
    } else if (draft.field('strength').confidence >= .65) {
      // Strength disagreement is a safety signal, not an auto-fill signal.
      // Use a lower threshold than the normal .78 review boundary so a
      // plausible printed dose can never be overwritten by a verified product
      // candidate merely because OCR confidence was slightly degraded.
      hardConflicts++;
    }
""",
)

replace(
    "tool/check_local_ai.dart",
    """        photoJob,
    'Rapid photo OCR has priority over long video and model work',
""",
    """        reasoningJob,
    'Ready photo reasoning gets its fair turn before the next queued photo',
""",
)

replace(
    "tool/check_local_ai.dart",
    """    'Video yields to a ready photo between windows',
""",
    """    'Video yields to ready photo reasoning between windows',
""",
)

Path("tool/.resolver_v2_ci_recheck").unlink(missing_ok=True)
Path("tool/resolver_v2_finalfix.py").unlink(missing_ok=True)
Path(".github/workflows/resolver_v2_finalfix.yml").unlink(missing_ok=True)
