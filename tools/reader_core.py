#!/usr/bin/env python3
"""Trusted, read-only Quran reader boundary for activated content packs.

This module deliberately exposes only source-faithful display text to the reader UI.
Search-normalized columns remain internal to retrieval. Word tap anchors are visual,
ephemeral spans and MUST NOT be persisted or interpreted as canonical TokenIDs.
"""
from __future__ import annotations

from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
import json
import re
import sqlite3
from typing import Iterator

from tools.pack_gate import validate_manifest


class ReaderCoreError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class QuranCoordinate:
    surah: int
    ayah: int

    def __post_init__(self) -> None:
        if not 1 <= self.surah <= 114:
            raise ValueError("surah must be between 1 and 114")
        if self.ayah < 1:
            raise ValueError("ayah must be >= 1")

    @property
    def ayah_id(self) -> str:
        return f"qa:{self.surah:03d}:{self.ayah:03d}"


@dataclass(frozen=True, slots=True)
class ReaderAyah:
    coordinate: QuranCoordinate
    original_text: str
    ayahs_in_surah: int
    previous: QuranCoordinate | None
    next: QuranCoordinate | None

    @property
    def ayah_id(self) -> str:
        return self.coordinate.ayah_id


@dataclass(frozen=True, slots=True)
class SurfaceTapAnchor:
    """UI-only span for hit testing inside immutable Quran display text.

    `anchor_id` is intentionally namespaced `ui-surface:` and is not a TokenID.
    The only authoritative identity carried here is the parent ayah coordinate.
    """

    anchor_id: str
    ayah_id: str
    ordinal: int
    start: int
    end: int
    surface: str
    canonical_token_id: None = None


class ReaderCore:
    """Read-only access to an already gated Quran content pack."""

    def __init__(self, artifact_path: Path):
        self._artifact_path = artifact_path.resolve()
        if not self._artifact_path.is_file():
            raise ReaderCoreError(f"missing reader artifact: {self._artifact_path}")
        self._assert_reader_schema()

    @classmethod
    def from_manifest(
        cls,
        manifest_path: Path,
        registry_path: Path,
        *,
        allow_unapproved_for_development: bool = False,
    ) -> "ReaderCore":
        """Fail closed through the existing Source Vault/content-pack gate.

        Production callers get an additional activation guard: a valid but unsigned
        candidate pack is not readable unless development code opts in explicitly.
        """
        manifest_path = manifest_path.resolve()
        registry_path = registry_path.resolve()
        validate_manifest(manifest_path, registry_path)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("pack_id") != "quran-core":
            raise ReaderCoreError("reader requires a quran-core content pack")
        if (
            manifest.get("review_status") != "approved"
            and not allow_unapproved_for_development
        ):
            raise ReaderCoreError(
                "reader refuses an unapproved Quran pack outside development"
            )
        root = registry_path.parents[1]
        artifact = (root / manifest["artifact_path"]).resolve()
        if artifact.parent != manifest_path.parent:
            raise ReaderCoreError("reader artifact must live beside its manifest")
        return cls(artifact)

    def _connect(self) -> sqlite3.Connection:
        # `mode=ro` is the runtime protection. `immutable=1` tells SQLite this
        # content pack will not change underneath an open reader connection.
        uri = f"{self._artifact_path.as_uri()}?mode=ro&immutable=1"
        connection = sqlite3.connect(uri, uri=True)
        connection.row_factory = sqlite3.Row
        return connection

    def _assert_reader_schema(self) -> None:
        try:
            with closing(self._connect()) as connection:
                cols = {
                    row[1]
                    for row in connection.execute("PRAGMA table_info(quran_ayah)")
                }
                required = {
                    "ayah_id",
                    "surah",
                    "ayah",
                    "original_text",
                    "search_unicode",
                    "search_diacritic_free",
                }
                if not required.issubset(cols):
                    missing = sorted(required - cols)
                    raise ReaderCoreError(
                        f"quran_ayah reader schema missing columns: {missing}"
                    )
        except sqlite3.Error as exc:
            raise ReaderCoreError(f"cannot open Quran reader pack: {exc}") from exc

    def get(self, coordinate: QuranCoordinate) -> ReaderAyah:
        with closing(self._connect()) as connection:
            row = connection.execute(
                """
                SELECT ayah_id, surah, ayah, original_text
                FROM quran_ayah
                WHERE surah = ? AND ayah = ?
                """,
                (coordinate.surah, coordinate.ayah),
            ).fetchone()
            if row is None:
                raise ReaderCoreError(
                    f"Quran coordinate not present: {coordinate.surah}:{coordinate.ayah}"
                )
            expected_id = coordinate.ayah_id
            if row["ayah_id"] != expected_id:
                raise ReaderCoreError(
                    f"canonical ayah identity mismatch at {coordinate.surah}:{coordinate.ayah}"
                )
            count = connection.execute(
                "SELECT COUNT(*) FROM quran_ayah WHERE surah = ?",
                (coordinate.surah,),
            ).fetchone()[0]
            previous = self._neighbor(connection, coordinate, backwards=True)
            next_coord = self._neighbor(connection, coordinate, backwards=False)

        return ReaderAyah(
            coordinate=coordinate,
            original_text=row["original_text"],
            ayahs_in_surah=count,
            previous=previous,
            next=next_coord,
        )

    @staticmethod
    def _neighbor(
        connection: sqlite3.Connection,
        coordinate: QuranCoordinate,
        *,
        backwards: bool,
    ) -> QuranCoordinate | None:
        if backwards:
            operator, order = "<", "DESC"
        else:
            operator, order = ">", "ASC"
        row = connection.execute(
            f"""
            SELECT surah, ayah
            FROM quran_ayah
            WHERE surah {operator} ?
               OR (surah = ? AND ayah {operator} ?)
            ORDER BY surah {order}, ayah {order}
            LIMIT 1
            """,
            (coordinate.surah, coordinate.surah, coordinate.ayah),
        ).fetchone()
        if row is None:
            return None
        return QuranCoordinate(row["surah"], row["ayah"])

    def first(self) -> ReaderAyah:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT surah, ayah FROM quran_ayah ORDER BY surah, ayah LIMIT 1"
            ).fetchone()
        if row is None:
            raise ReaderCoreError("Quran pack contains no ayahs")
        return self.get(QuranCoordinate(row["surah"], row["ayah"]))

    def last(self) -> ReaderAyah:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT surah, ayah FROM quran_ayah ORDER BY surah DESC, ayah DESC LIMIT 1"
            ).fetchone()
        if row is None:
            raise ReaderCoreError("Quran pack contains no ayahs")
        return self.get(QuranCoordinate(row["surah"], row["ayah"]))

    def iter_coordinates(self) -> Iterator[QuranCoordinate]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                "SELECT surah, ayah FROM quran_ayah ORDER BY surah, ayah"
            ).fetchall()
        for row in rows:
            yield QuranCoordinate(row["surah"], row["ayah"])

    @staticmethod
    def surface_tap_anchors(ayah: ReaderAyah) -> tuple[SurfaceTapAnchor, ...]:
        """Derive visual hit-test spans without creating Evidence Plane tokens.

        Splitting for hit testing is not morphology. These anchors are never written
        to `quran_token`, never receive LexemeIDs, and disappear when the view does.
        """
        anchors: list[SurfaceTapAnchor] = []
        for ordinal, match in enumerate(re.finditer(r"\S+", ayah.original_text), start=1):
            anchors.append(
                SurfaceTapAnchor(
                    anchor_id=f"ui-surface:{ayah.ayah_id}:{ordinal:03d}",
                    ayah_id=ayah.ayah_id,
                    ordinal=ordinal,
                    start=match.start(),
                    end=match.end(),
                    surface=match.group(0),
                )
            )
        return tuple(anchors)
