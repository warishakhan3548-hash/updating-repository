#!/usr/bin/env python3
"""Pinned Tanzil Quran source parsing and derived search normalization."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import unicodedata

SOURCE_ID = "quran.tanzil.uthmani.v1.1"
SEARCH_NORMALIZATION_VERSION = "arabic-search-v1"

EXPECTED_AYAH_COUNTS = (
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52,
    99, 128, 111, 110, 98, 135, 112, 78, 118, 64, 77, 227, 93, 88,
    69, 60, 34, 30, 73, 54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59,
    37, 35, 38, 29, 18, 45, 60, 49, 62, 55, 78, 96, 29, 22, 24, 13,
    14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28, 28, 20, 56, 40, 31,
    50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19, 26, 30, 20, 15, 21,
    11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3, 6, 3, 5, 4,
    5, 6,
)

# Derived search-only removals. Display/source text is never rewritten.
_REMOVE_RANGES = (
    (0x0610, 0x061A),
    (0x064B, 0x065F),
    (0x06D6, 0x06DC),
    (0x06DF, 0x06E6),
    (0x06E7, 0x06E8),
    (0x06EA, 0x06ED),
    (0x08D3, 0x08FF),
)
_REMOVE_SINGLE = {
    0x0640,  # TATWEEL
    0x0670,  # ARABIC LETTER SUPERSCRIPT ALEF
    0x06DD,  # END OF AYAH
    0x06DE,  # START OF RUB EL HIZB
    0x06E9,  # PLACE OF SAJDAH
}


class QuranSourceError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class AyahRow:
    surah: int
    ayah: int
    original_text: str

    @property
    def ayah_id(self) -> str:
        return f"qa:{self.surah:03d}:{self.ayah:03d}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_coordinates() -> tuple[tuple[int, int], ...]:
    return tuple(
        (surah, ayah)
        for surah, count in enumerate(EXPECTED_AYAH_COUNTS, start=1)
        for ayah in range(1, count + 1)
    )


def normalize_search_unicode(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def _remove_for_diacritic_lane(char: str) -> bool:
    cp = ord(char)
    if cp in _REMOVE_SINGLE:
        return True
    return any(start <= cp <= end for start, end in _REMOVE_RANGES)


def normalize_search_diacritic_free(text: str) -> str:
    canonical = normalize_search_unicode(text)
    stripped = "".join(ch for ch in canonical if not _remove_for_diacritic_lane(ch))
    return " ".join(stripped.split())


def extract_tanzil_notice(path: Path) -> str:
    """Extract the source-supplied notice comments for runtime redistribution."""
    raw = path.read_text(encoding="utf-8")
    comment_lines = [
        line[1:].lstrip()
        for line in raw.splitlines()
        if line.startswith("#")
    ]
    notice = "\\n".join(comment_lines).strip()
    required_notice = (
        "Tanzil Quran Text (Uthmani, Version 1.1)",
        "Creative Commons Attribution 3.0",
        "CHANGING IT IS NOT ALLOWED",
    )
    for marker in required_notice:
        if marker not in notice:
            raise QuranSourceError(f"source notice missing required marker: {marker}")
    return notice


def load_tanzil_txt2(path: Path) -> list[AyahRow]:
    raw = path.read_text(encoding="utf-8")
    required_notice = (
        "Tanzil Quran Text (Uthmani, Version 1.1)",
        "Creative Commons Attribution 3.0",
        "CHANGING IT IS NOT ALLOWED",
    )
    for marker in required_notice:
        if marker not in raw:
            raise QuranSourceError(f"source artifact missing required marker: {marker}")

    rows: list[AyahRow] = []
    for line_number, line in enumerate(raw.splitlines(), start=1):
        if not line or line.startswith("#"):
            continue
        parts = line.split("|", 2)
        if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
            raise QuranSourceError(f"unexpected non-comment line {line_number}")
        surah, ayah = int(parts[0]), int(parts[1])
        text = parts[2]
        if not text.strip():
            raise QuranSourceError(f"empty Quran text at {surah}:{ayah}")
        rows.append(AyahRow(surah=surah, ayah=ayah, original_text=text))

    actual = tuple((row.surah, row.ayah) for row in rows)
    expected = expected_coordinates()
    if actual != expected:
        mismatch = next(
            (
                index
                for index, pair in enumerate(zip(actual, expected), start=1)
                if pair[0] != pair[1]
            ),
            None,
        )
        if len(actual) != len(expected):
            detail = f"expected {len(expected)} rows, found {len(actual)}"
        elif mismatch is not None:
            detail = (
                f"coordinate mismatch at row {mismatch}: "
                f"found {actual[mismatch - 1]}, expected {expected[mismatch - 1]}"
            )
        else:
            detail = "coordinate set mismatch"
        raise QuranSourceError(detail)
    return rows


def load_production_source(root: Path) -> tuple[dict, Path, list[AyahRow]]:
    registry_path = root / "source-vault" / "registry.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    source = next(
        (entry for entry in registry.get("sources", []) if entry.get("source_id") == SOURCE_ID),
        None,
    )
    if source is None:
        raise QuranSourceError(f"missing source registry entry: {SOURCE_ID}")
    if source.get("status") != "production-approved":
        raise QuranSourceError(f"{SOURCE_ID} is not production-approved")
    if source.get("redistribution_allowed") is not True:
        raise QuranSourceError(f"{SOURCE_ID} lacks redistribution approval")

    raw_path = source.get("vault_artifact")
    if not isinstance(raw_path, str) or not raw_path.startswith("source-vault/"):
        raise QuranSourceError("invalid vault_artifact path")
    artifact = root / raw_path
    if not artifact.is_file():
        raise QuranSourceError(f"missing preserved artifact: {raw_path}")

    expected_hash = source.get("sha256")
    expected_size = source.get("byte_size")
    actual_hash = sha256_file(artifact)
    actual_size = artifact.stat().st_size
    if actual_hash != expected_hash:
        raise QuranSourceError("preserved Quran artifact SHA-256 mismatch")
    if actual_size != expected_size:
        raise QuranSourceError("preserved Quran artifact byte-size mismatch")

    return source, artifact, load_tanzil_txt2(artifact)
