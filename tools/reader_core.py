#!/usr/bin/env python3
"""Read-only Quran reader projection over a validated local content pack."""
from __future__ import annotations

from dataclasses import dataclass
import argparse
import json
from pathlib import Path
import sqlite3
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.pack_gate import PackGateError, validate_manifest

PACK_ID = "quran-core"
DEFAULT_MANIFEST = Path("content-packs/quran-core/1.0.4/manifest.json")
WORD_LAYER_METADATA_KEY = "quran_token_layer_status"
WORD_LAYER_COMPLETE = "complete"


class ReaderError(RuntimeError):
    """Raised when the local reader cannot safely expose verified content."""


@dataclass(frozen=True, slots=True)
class ReaderAyah:
    ayah_id: str
    surah: int
    ayah: int
    original_text: str
    source_assertion_id: str


@dataclass(frozen=True, slots=True)
class ReaderToken:
    token_id: str
    ayah_id: str
    token_index: int
    original_text: str


class QuranReader:
    """Fail-closed projection that never exposes search-normalized text as display data."""

    def __init__(
        self,
        connection: sqlite3.Connection,
        manifest: dict,
        metadata: dict[str, str],
    ) -> None:
        self._connection = connection
        self._manifest = manifest
        self._metadata = metadata

    @classmethod
    def open(
        cls,
        root: Path,
        manifest_path: Path = DEFAULT_MANIFEST,
    ) -> "QuranReader":
        root = root.resolve()
        manifest_path = manifest_path if manifest_path.is_absolute() else root / manifest_path
        registry_path = root / "source-vault" / "registry.json"

        try:
            validate_manifest(manifest_path, registry_path)
        except (OSError, ValueError, json.JSONDecodeError, PackGateError) as exc:
            raise ReaderError(f"content pack validation failed: {exc}") from exc

        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ReaderError("reader manifest is unreadable") from exc

        if manifest.get("pack_id") != PACK_ID:
            raise ReaderError(f"unsupported reader pack: {manifest.get('pack_id')!r}")

        artifact_path = root / manifest["artifact_path"]
        uri = artifact_path.resolve().as_uri() + "?mode=ro&immutable=1"
        try:
            connection = sqlite3.connect(uri, uri=True)
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA query_only = ON")
            metadata = dict(
                connection.execute("SELECT key, value FROM pack_metadata").fetchall()
            )
        except sqlite3.Error as exc:
            raise ReaderError("unable to open local Quran content pack read-only") from exc

        expected_metadata = {
            "pack_id": PACK_ID,
            "content_version": manifest["content_version"],
            "source_id": manifest["source_id"],
            "source_sha256": manifest["source_sha256"],
        }
        mismatched = [
            key for key, value in expected_metadata.items() if metadata.get(key) != value
        ]
        if mismatched:
            connection.close()
            raise ReaderError(f"reader pack metadata mismatch: {mismatched}")

        reader = cls(connection=connection, manifest=manifest, metadata=metadata)
        reader._validate_word_layer_contract()
        return reader

    @property
    def content_version(self) -> str:
        return self._manifest["content_version"]

    @property
    def word_layer_status(self) -> str:
        return self._metadata.get(WORD_LAYER_METADATA_KEY, "absent")

    @property
    def word_tap_ready(self) -> bool:
        return self.word_layer_status == WORD_LAYER_COMPLETE

    def _validate_word_layer_contract(self) -> None:
        status = self.word_layer_status
        if status not in {"absent", WORD_LAYER_COMPLETE}:
            self.close()
            raise ReaderError(f"unsupported Quran token layer status: {status!r}")

        token_count = self._connection.execute(
            "SELECT COUNT(*) FROM quran_token"
        ).fetchone()[0]

        if status == "absent":
            if token_count != 0:
                self.close()
                raise ReaderError(
                    "Quran token rows exist without an explicit complete token-layer marker"
                )
            return

        ayah_count = self._connection.execute(
            "SELECT COUNT(*) FROM quran_ayah"
        ).fetchone()[0]
        token_ayah_count = self._connection.execute(
            "SELECT COUNT(DISTINCT ayah_id) FROM quran_token"
        ).fetchone()[0]
        if ayah_count == 0 or token_count == 0 or token_ayah_count != ayah_count:
            self.close()
            raise ReaderError(
                "complete Quran token layer marker requires token coverage for every ayah"
            )

    @staticmethod
    def _validate_surah(surah: int) -> None:
        if isinstance(surah, bool) or not isinstance(surah, int) or not 1 <= surah <= 114:
            raise ReaderError(f"invalid surah: {surah!r}")

    @staticmethod
    def _validate_ayah_number(ayah: int) -> None:
        if isinstance(ayah, bool) or not isinstance(ayah, int) or ayah < 1:
            raise ReaderError(f"invalid ayah: {ayah!r}")

    def get_ayah(self, surah: int, ayah: int) -> ReaderAyah:
        self._validate_surah(surah)
        self._validate_ayah_number(ayah)
        row = self._connection.execute(
            """
            SELECT ayah_id, surah, ayah, original_text, source_assertion_id
            FROM quran_ayah
            WHERE surah = ? AND ayah = ?
            """,
            (surah, ayah),
        ).fetchone()
        if row is None:
            raise ReaderError(f"Quran coordinate not found: {surah}:{ayah}")
        return ReaderAyah(
            ayah_id=row["ayah_id"],
            surah=row["surah"],
            ayah=row["ayah"],
            original_text=row["original_text"],
            source_assertion_id=row["source_assertion_id"],
        )

    def list_surah(self, surah: int) -> tuple[ReaderAyah, ...]:
        self._validate_surah(surah)
        rows = self._connection.execute(
            """
            SELECT ayah_id, surah, ayah, original_text, source_assertion_id
            FROM quran_ayah
            WHERE surah = ?
            ORDER BY ayah
            """,
            (surah,),
        ).fetchall()
        if not rows:
            raise ReaderError(f"surah not found: {surah}")
        return tuple(
            ReaderAyah(
                ayah_id=row["ayah_id"],
                surah=row["surah"],
                ayah=row["ayah"],
                original_text=row["original_text"],
                source_assertion_id=row["source_assertion_id"],
            )
            for row in rows
        )

    def tokens_for_ayah(self, surah: int, ayah: int) -> tuple[ReaderToken, ...]:
        target = self.get_ayah(surah, ayah)
        if not self.word_tap_ready:
            return ()
        rows = self._connection.execute(
            """
            SELECT token_id, ayah_id, token_index, original_text
            FROM quran_token
            WHERE ayah_id = ?
            ORDER BY token_index
            """,
            (target.ayah_id,),
        ).fetchall()
        return tuple(
            ReaderToken(
                token_id=row["token_id"],
                ayah_id=row["ayah_id"],
                token_index=row["token_index"],
                original_text=row["original_text"],
            )
            for row in rows
        )

    def close(self) -> None:
        self._connection.close()

    def __enter__(self) -> "QuranReader":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Read immutable Quran display text from a validated local content pack."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help="content-pack manifest path relative to repository root",
    )
    parser.add_argument("--surah", type=int, required=True)
    parser.add_argument("--ayah", type=int)
    args = parser.parse_args()

    with QuranReader.open(args.root, args.manifest) as reader:
        if args.ayah is not None:
            print(reader.get_ayah(args.surah, args.ayah).original_text)
            return
        for row in reader.list_surah(args.surah):
            print(f"{row.surah}:{row.ayah}|{row.original_text}")


if __name__ == "__main__":
    main()
