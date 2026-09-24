#!/usr/bin/env python3
"""Offline end-to-end verifier for the vendored Aaris Hadith pack.

No network, Android SDK, APK build or CI is used. The verifier:
1. reconstructs/verifies the pinned Open-Hadith-Data source;
2. checks exact collection and record coverage;
3. builds a temporary hadith.sqlite;
4. verifies SQLite integrity, FTS, per-collection counts and source hashes.
"""
import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
from prepare_open_hadith_data import display_text, plain_identity, plain_records, source_paths, vocalized_records
from build_hadith import normalize_arabic

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "source-vault" / "hadith" / "open-hadith-data"


def check_rejections(scratch):
    """Swapped narrations and dropped marks must not be accepted as a presentation update."""
    path = scratch / "fixture.csv.gz"
    baseline = {"1": "إنما الأعمال بالنيات"}
    correct = "\u200f إِنَّمَا  الْأَعْمَالُ بِالنِّيَّاتِ \u200f"
    def write(rows):
        with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
            csv.writer(f).writerows(rows)
    write([["1", correct, "Commentary is not the narration or a translation"]])
    assert list(vocalized_records(path, 3, baseline)) == [("1", display_text(correct))]
    for rows in [
        [["1", "إنما الأعمال بالنيات", ""]],  # stripped display text
        [["2", correct, ""]],  # wrong number
        [["1", "إِنَّمَا الْأَعْمَالُ بِالأَقْوَالِ", ""]],  # different words
        [["1", correct, ""], ["1", correct, ""]],  # duplicate
        [],  # incomplete download
    ]:
        write(rows)
        try:
            list(vocalized_records(path, 3, baseline))
        except ValueError:
            pass
        else:
            raise AssertionError("Accepted an invalid vocalized source fixture")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    args = parser.parse_args()

    source = args.source.resolve()
    inventory = json.loads((source / "SOURCE.json").read_text(encoding="utf-8"))
    expected = {
        collection_id: int(meta["expected_record_count"])
        for collection_id, meta in inventory["collections"].items()
    }
    if set(expected) != {
        "bukhari", "muslim", "nasai", "abudawud", "tirmidhi",
        "ibnmajah", "malik", "ahmad", "darimi",
    }:
        raise SystemExit("Unexpected core-nine collection inventory")
    expected_total = sum(expected.values())
    if expected_total != 62169:
        raise SystemExit(f"Unexpected pinned record total: {expected_total}")

    with tempfile.TemporaryDirectory(prefix="aaris-hadith-check-") as scratch:
        scratch = Path(scratch)
        check_rejections(scratch)
        prepared = scratch / "prepared"
        sqlite_path = scratch / "hadith.sqlite"

        subprocess.run([
            sys.executable,
            str(ROOT / "tools" / "prepare_open_hadith_data.py"),
            "--source", str(source),
            "--output", str(prepared),
        ], check=True, cwd=ROOT, stdout=subprocess.DEVNULL)

        prepared_manifest = json.loads((prepared / "manifest.json").read_text(encoding="utf-8"))
        counts = {k: int(v) for k, v in prepared_manifest["collection_record_counts"].items()}
        assert counts == expected, (counts, expected)
        assert prepared_manifest["runtime_network_required"] is False
        assert prepared_manifest["language_coverage"] == ["ar"]
        assert prepared_manifest["require_vowel_marks"] is True
        assert prepared_manifest["vocalization"]["generated"] is False
        assert prepared_manifest["vocalization"]["records_with_vowel_marks"] == expected_total
        assert prepared_manifest["required_collection_ids"] == [
            "bukhari", "muslim", "nasai", "abudawud", "tirmidhi",
            "ibnmajah", "malik", "ahmad", "darimi",
        ]

        subprocess.run([
            sys.executable,
            str(ROOT / "tools" / "build_hadith.py"),
            "--source", str(prepared),
            "--output", str(sqlite_path),
        ], check=True, cwd=ROOT, stdout=subprocess.DEVNULL)

        generated = json.loads((sqlite_path.parent / "hadith-manifest.json").read_text(encoding="utf-8"))
        assert generated["schema_version"] == 2
        assert generated["collections"] == 9
        assert generated["records"] == expected_total
        assert generated["language_coverage"] == ["ar"]
        assert generated["runtime_network_required"] is False
        assert generated["arabic_records_with_vowel_marks"] == expected_total
        assert generated["vocalization"]["origin"] == "published-upstream"
        assert hashlib.sha256(sqlite_path.read_bytes()).hexdigest() == generated["sqlite_sha256"]

        db = sqlite3.connect(f"file:{sqlite_path}?mode=ro", uri=True)
        try:
            assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            assert db.execute("PRAGMA user_version").fetchone()[0] == 2
            assert not db.execute("PRAGMA foreign_key_check").fetchall()
            assert db.execute("SELECT count(*) FROM collection").fetchone()[0] == 9
            assert db.execute("SELECT count(*) FROM hadith").fetchone()[0] == expected_total
            assert db.execute("SELECT count(*) FROM hadith_fts").fetchone()[0] == expected_total
            assert db.execute("SELECT count(*) FROM editorial_translation").fetchone()[0] == 0

            actual = dict(db.execute(
                "SELECT collection_id,COUNT(*) FROM hadith GROUP BY collection_id ORDER BY collection_id"
            ))
            assert actual == expected, (actual, expected)

            for collection_id, count in expected.items():
                first = db.execute(
                    "SELECT record_number FROM hadith WHERE collection_id=? ORDER BY CAST(record_number AS INTEGER) LIMIT 1",
                    (collection_id,),
                ).fetchone()[0]
                last = db.execute(
                    "SELECT record_number FROM hadith WHERE collection_id=? ORDER BY CAST(record_number AS INTEGER) DESC LIMIT 1",
                    (collection_id,),
                ).fetchone()[0]
                assert first == "1"
                assert last == str(count)

            for arabic, expected_hash in db.execute("SELECT arabic,source_sha256 FROM hadith"):
                assert hashlib.sha256(arabic.encode("utf-8")).hexdigest() == expected_hash

            # Independently compare every installed record with the archived vocalized column.
            # Strip layout only: a changed vowel, letter, number or lost record fails this check.
            for cid, meta in inventory["collections"].items():
                plain = plain_records(source_paths(source, meta["local"]))
                installed = dict(db.execute(
                    "SELECT record_number,arabic FROM hadith WHERE collection_id=?", (cid,)))
                checked = set()
                with gzip.open(source / meta["vocalized"]["local"], "rt",
                               encoding="utf-8-sig", newline="") as f:
                    for row in csv.reader(f, strict=True):
                        number = row[0].strip()
                        original = " ".join(row[1].replace("\u200f", "").split())
                        assert installed[number] == original, (cid, number, "source text changed")
                        assert plain_identity(installed[number]) == plain[number], (cid, number)
                        checked.add(number)
                assert checked == set(installed) == set(plain)
                edition = "open-hadith-data-" + inventory["upstream_commit"][:12]
                for hid, number in db.execute("SELECT id,record_number FROM hadith WHERE collection_id=?", (cid,)):
                    assert hid == f"H:{cid}:{edition}:0:{number}", "Existing record identity changed"

            # FTS must resolve a known Arabic token without touching the network.
            sample = db.execute("SELECT arabic FROM hadith WHERE collection_id='bukhari' AND record_number='1'").fetchone()
            assert sample and sample[0]
            token = next((part for part in normalize_arabic(sample[0]).split() if len(part) >= 3), None)
            assert token
            assert db.execute(
                "SELECT count(*) FROM hadith_fts WHERE hadith_fts MATCH ?", (f'"{token}"',)
            ).fetchone()[0] >= 1
        finally:
            db.close()

    print(json.dumps({
        "status": "PASS",
        "collections": 9,
        "records": expected_total,
        "vocalized_records": expected_total,
        "source_wording_and_identity_matches": expected_total,
        "generated_diacritics": False,
        "language_coverage": ["ar"],
        "runtime_network_required": False,
        "apk_built": False,
        "ci_started": False,
    }, indent=2))


if __name__ == "__main__":
    main()
