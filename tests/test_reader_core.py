import json
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from tools.reader_core import QuranCoordinate, ReaderCore, ReaderCoreError


ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "source-vault" / "registry.json"


def _latest_quran_pack_manifest() -> Path:
    root = ROOT / "content-packs" / "quran-core"
    manifests = list(root.glob("*/manifest.json"))
    if not manifests:
        return root / "missing" / "manifest.json"

    def version_key(path: Path) -> tuple[int, ...]:
        try:
            return tuple(int(part) for part in path.parent.name.split("."))
        except ValueError:
            return (-1,)

    return max(manifests, key=version_key)


PACK_MANIFEST = _latest_quran_pack_manifest()


class ReaderCoreSyntheticTests(unittest.TestCase):
    def _make_db(self, root: Path) -> Path:
        db = root / "content.sqlite"
        with sqlite3.connect(db) as connection:
            connection.executescript(
                """
                CREATE TABLE quran_ayah (
                    ayah_id TEXT PRIMARY KEY,
                    surah INTEGER NOT NULL,
                    ayah INTEGER NOT NULL,
                    original_text TEXT NOT NULL,
                    search_unicode TEXT NOT NULL,
                    search_diacritic_free TEXT NOT NULL,
                    UNIQUE(surah, ayah)
                );
                INSERT INTO quran_ayah VALUES
                    ('qa:001:001', 1, 1, 'أ ب  ج', 'search-only-1', 'normalized-only-1'),
                    ('qa:001:002', 1, 2, 'د هـ', 'search-only-2', 'normalized-only-2'),
                    ('qa:002:001', 2, 1, 'و', 'search-only-3', 'normalized-only-3');
                """
            )
        return db

    def test_reader_exposes_original_text_only_and_stable_neighbors(self):
        with tempfile.TemporaryDirectory() as tmp:
            reader = ReaderCore(self._make_db(Path(tmp)))
            ayah = reader.get(QuranCoordinate(1, 2))
            self.assertEqual(ayah.original_text, 'د هـ')
            self.assertEqual(ayah.ayah_id, 'qa:001:002')
            self.assertEqual(ayah.ayahs_in_surah, 2)
            self.assertEqual(ayah.previous, QuranCoordinate(1, 1))
            self.assertEqual(ayah.next, QuranCoordinate(2, 1))
            self.assertFalse(hasattr(ayah, 'search_unicode'))
            self.assertFalse(hasattr(ayah, 'search_diacritic_free'))

    def test_surface_anchors_are_ephemeral_spans_not_canonical_tokens(self):
        with tempfile.TemporaryDirectory() as tmp:
            reader = ReaderCore(self._make_db(Path(tmp)))
            ayah = reader.get(QuranCoordinate(1, 1))
            anchors = reader.surface_tap_anchors(ayah)
            self.assertEqual([a.surface for a in anchors], ['أ', 'ب', 'ج'])
            for anchor in anchors:
                self.assertTrue(anchor.anchor_id.startswith('ui-surface:qa:001:001:'))
                self.assertIsNone(anchor.canonical_token_id)
                self.assertEqual(
                    ayah.original_text[anchor.start:anchor.end], anchor.surface
                )

    def test_invalid_coordinate_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            reader = ReaderCore(self._make_db(Path(tmp)))
            with self.assertRaises(ReaderCoreError):
                reader.get(QuranCoordinate(1, 9))

    def test_database_is_opened_read_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            reader = ReaderCore(self._make_db(Path(tmp)))
            with closing(reader._connect()) as connection:
                with self.assertRaises(sqlite3.OperationalError):
                    connection.execute(
                        "UPDATE quran_ayah SET original_text = 'mutated' WHERE surah = 1"
                    )

    def test_manifest_path_rejects_candidate_without_explicit_development_opt_in(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifact_dir = root / "content-packs" / "quran-core" / "test"
            artifact_dir.mkdir(parents=True)
            artifact = self._make_db(artifact_dir)
            registry = root / "source-vault" / "registry.json"
            registry.parent.mkdir(parents=True)
            registry.write_text("{}", encoding="utf-8")
            manifest = artifact_dir / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "pack_id": "quran-core",
                        "review_status": "candidate",
                        "artifact_path": str(artifact.relative_to(root)),
                    }
                ),
                encoding="utf-8",
            )
            with patch("tools.reader_core.validate_manifest", return_value=None):
                with self.assertRaisesRegex(ReaderCoreError, "unapproved Quran pack"):
                    ReaderCore.from_manifest(manifest, registry)
                reader = ReaderCore.from_manifest(
                    manifest,
                    registry,
                    allow_unapproved_for_development=True,
                )
                self.assertEqual(reader.first().coordinate, QuranCoordinate(1, 1))


@unittest.skipUnless(PACK_MANIFEST.is_file() and REGISTRY.is_file(), 'repo pack fixture unavailable')
class ReaderCorePublishedPackTests(unittest.TestCase):
    def setUp(self):
        self.reader = ReaderCore.from_manifest(
            PACK_MANIFEST, REGISTRY, allow_unapproved_for_development=True
        )

    def test_published_pack_has_complete_ordered_coordinate_set(self):
        coordinates = list(self.reader.iter_coordinates())
        self.assertEqual(len(coordinates), 6236)
        self.assertEqual(coordinates[0], QuranCoordinate(1, 1))
        self.assertEqual(coordinates[-1], QuranCoordinate(114, 6))
        self.assertEqual(len(set(coordinates)), 6236)

    def test_reader_first_and_last_navigation_edges(self):
        first = self.reader.first()
        last = self.reader.last()
        self.assertIsNone(first.previous)
        self.assertEqual(first.coordinate, QuranCoordinate(1, 1))
        self.assertIsNone(last.next)
        self.assertEqual(last.coordinate, QuranCoordinate(114, 6))

    def test_reader_text_is_byte_for_byte_database_original_text(self):
        manifest = json.loads(PACK_MANIFEST.read_text(encoding='utf-8'))
        db = ROOT / manifest['artifact_path']
        with sqlite3.connect(db) as connection:
            expected = connection.execute(
                "SELECT original_text FROM quran_ayah WHERE surah = 2 AND ayah = 255"
            ).fetchone()[0]
        actual = self.reader.get(QuranCoordinate(2, 255))
        self.assertEqual(actual.original_text, expected)

    def test_current_pack_does_not_invent_canonical_word_rows(self):
        manifest = json.loads(PACK_MANIFEST.read_text(encoding='utf-8'))
        db = ROOT / manifest['artifact_path']
        with sqlite3.connect(db) as connection:
            count = connection.execute('SELECT COUNT(*) FROM quran_token').fetchone()[0]
        self.assertEqual(count, 0)


if __name__ == '__main__':
    unittest.main()
