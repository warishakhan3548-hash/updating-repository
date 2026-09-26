#!/usr/bin/env python3
"""Offline end-to-end verifier for the bundled Aaris Hadith evidence pack.

The check independently verifies the pinned vocalized core-nine source, the checked-in official
HadeethEnc Arabic/English/Urdu/Hindi snapshots, the normalized source pack and final SQLite.
No network, API key, Android SDK or APK build is required.
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

from prepare_open_hadith_data import (
    display_text, plain_identity, plain_records, source_paths, vocalized_records
)
from build_hadith import normalize_arabic, search_text
from hadeethenc_xlsx import parse_workbook, source_identity

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "source-vault" / "hadith" / "open-hadith-data"
HADEETHENC = ROOT / "source-vault" / "hadith" / "hadeethenc" / "current"
CORE_IDS = [
    "bukhari", "muslim", "nasai", "abudawud", "tirmidhi",
    "ibnmajah", "malik", "ahmad", "darimi",
]


def check_rejections(scratch):
    """Swapped narrations and dropped marks must not be accepted as a source update."""
    path = scratch / "fixture.csv.gz"
    baseline = {"1": "إنما الأعمال بالنيات"}
    correct = "\u200f إِنَّمَا  الْأَعْمَالُ بِالنِّيَّاتِ \u200f"

    def write(rows):
        with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
            csv.writer(f).writerows(rows)

    write([["1", correct, "Commentary is not the narration or a translation"]])
    assert list(vocalized_records(path, 3, baseline)) == [("1", display_text(correct))]
    for rows in [
        [["1", "إنما الأعمال بالنيات", ""]],
        [["2", correct, ""]],
        [["1", "إِنَّمَا الْأَعْمَالُ بِالأَقْوَالِ", ""]],
        [["1", correct, ""], ["1", correct, ""]],
        [],
    ]:
        write(rows)
        try:
            list(vocalized_records(path, 3, baseline))
        except ValueError:
            pass
        else:
            raise AssertionError("Accepted an invalid vocalized source fixture")


def checked_hadeethenc():
    manifest = json.loads((HADEETHENC / "manifest.json").read_text(encoding="utf-8"))
    declared = {item["language"]: item for item in manifest["languages"]}
    assert set(declared) == {"ar", "en", "ur", "hi"}
    parsed = {}
    for language in ("ar", "en", "ur", "hi"):
        path = HADEETHENC / f"{language}.xlsx"
        meta = declared[language]
        assert path.stat().st_size == int(meta["bytes"])
        assert hashlib.sha256(path.read_bytes()).hexdigest() == meta["sha256"]
        parsed[language] = parse_workbook(path, language)
        if parsed[language]["version"]:
            assert parsed[language]["version"] == str(meta["version"])

    canonical = parsed["ar"]["records"]
    withheld = {}
    for language in ("en", "ur", "hi"):
        records = parsed[language]["records"]
        assert set(records) <= set(canonical)
        withheld[language] = [
            hid for hid, row in records.items()
            if source_identity(row["arabic"]) != source_identity(canonical[hid]["arabic"])
        ]
    return manifest, parsed, withheld


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    args = parser.parse_args()

    # Lifecycle regression: a selected Hadith can live on a later search page. After Activity
    # recreation only the first search page is reloaded, so PDF/compare must resolve saved IDs from
    # the immutable local pack instead of silently dropping selections that are not in hadithHits.
    main_activity_text = (ROOT / "app/src/main/java/com/aaris/quran/MainActivity.java").read_text(encoding="utf-8")
    hadith_store_text = (ROOT / "app/src/main/java/com/aaris/quran/HadithStore.java").read_text(encoding="utf-8")
    research_export_text = (ROOT / "app/src/main/java/com/aaris/quran/ResearchExport.java").read_text(encoding="utf-8")
    assert "List<Record> records(Collection<String> ids)" in hadith_store_text
    assert "for(int start=0;start<all.size();start+=400)" in hadith_store_text, "Saved Hadith ID resolution must stay below SQLite bind limits"
    assert "static Hit selected(Record record)" in hadith_store_text and "selectionOnly" in hadith_store_text
    assert "private void resolveHadithResearchSelection(List<HadithStore.Hit> loaded)" in main_activity_text
    resolver_start = main_activity_text.index("    private void resolveHadithResearchSelection(")
    resolver_end = main_activity_text.index("\n    private void shareResearch(boolean hadith)", resolver_start)
    resolver = main_activity_text[resolver_start:resolver_end]
    assert "hadithBrowseWorker.submit" in resolver and "store.records(missing)" in resolver, "Off-page selected Hadith resolution must stay off the Android UI thread"
    assert "HadithStore.Hit.selected(record)" in resolver, "Restored selections need a neutral source-only evidence state"
    assert "if(!selectedHadith.isEmpty()&&hits.size()<selectedHadith.size())" in main_activity_text
    assert "ResearchExport.hadithRetrievalLabel(hit)" in main_activity_text
    assert "Selected source records for comparison. Search-match details are shown only where still available" in main_activity_text, "Restored Hadith comparison must not describe source-only selections as fresh search matches"
    assert "if(hit.selectionOnly)return \"SELECTED SOURCE" in research_export_text, "Restored selection exports must not fabricate search-match confidence"

    source = args.source.resolve()
    inventory = json.loads((source / "SOURCE.json").read_text(encoding="utf-8"))
    expected_core = {
        collection_id: int(meta["expected_record_count"])
        for collection_id, meta in inventory["collections"].items()
    }
    if list(expected_core) != CORE_IDS:
        raise SystemExit("Unexpected core-nine collection inventory/order")
    core_total = sum(expected_core.values())
    if core_total != 62169:
        raise SystemExit(f"Unexpected pinned record total: {core_total}")

    hadeethenc_manifest, hadeethenc, he_withheld = checked_hadeethenc()
    he_count = len(hadeethenc["ar"]["records"])
    he_translation_counts = {
        language: len(hadeethenc[language]["records"]) - len(he_withheld[language])
        for language in ("en", "ur", "hi")
    }
    expected_all = dict(expected_core)
    expected_all["hadeethenc"] = he_count
    final_total = core_total + he_count

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
        assert counts == expected_all, (counts, expected_all)
        assert prepared_manifest["runtime_network_required"] is False
        assert set(prepared_manifest["language_coverage"]) == {"ar", "en", "hi", "ur"}
        assert prepared_manifest["vocalization"]["generated"] is False
        assert prepared_manifest["vocalization"]["records_with_vowel_marks"] == core_total
        assert prepared_manifest["required_collection_ids"] == CORE_IDS + ["hadeethenc"]
        assert prepared_manifest["require_vowel_marks_collection_ids"] == CORE_IDS
        assert prepared_manifest["hadeethenc_translation_record_counts"] == he_translation_counts
        context_counts = prepared_manifest["hadeethenc_search_context_counts"]
        assert set(context_counts) == {"ar","en","ur","hi"} and all(int(v)>0 for v in context_counts.values())
        assert prepared_manifest["hadeethenc_withheld_translation_ids"] == he_withheld

        subprocess.run([
            sys.executable,
            str(ROOT / "tools" / "build_hadith.py"),
            "--source", str(prepared),
            "--output", str(sqlite_path),
        ], check=True, cwd=ROOT, stdout=subprocess.DEVNULL)

        generated = json.loads((sqlite_path.parent / "hadith-manifest.json").read_text(encoding="utf-8"))
        assert generated["schema_version"] == 2
        assert generated["collections"] == 10
        assert generated["records"] == final_total
        assert set(generated["language_coverage"]) == {"ar", "en", "hi", "ur"}
        assert generated["runtime_network_required"] is False
        assert generated["vocalized_required_collection_ids"] == CORE_IDS
        assert generated["arabic_records_with_vowel_marks"] >= core_total
        assert generated["vocalization"]["origin"] == "published-upstream"
        assert generated["editorial_translations"] == sum(he_translation_counts.values())
        assert generated["search_contexts"] == sum(int(v) for v in context_counts.values())
        assert generated["hadeethenc_translation_record_counts"] == he_translation_counts
        assert generated["hadeethenc_withheld_translation_ids"] == he_withheld
        assert hashlib.sha256(sqlite_path.read_bytes()).hexdigest() == generated["sqlite_sha256"]
        assert sqlite_path.stat().st_size == int(generated["sqlite_bytes"]) and int(generated["sqlite_bytes"]) > 0

        db = sqlite3.connect(f"file:{sqlite_path}?mode=ro", uri=True)
        try:
            assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            assert db.execute("PRAGMA user_version").fetchone()[0] == 2
            assert not db.execute("PRAGMA foreign_key_check").fetchall()
            assert db.execute("SELECT count(*) FROM collection").fetchone()[0] == 10
            assert db.execute("SELECT count(*) FROM hadith").fetchone()[0] == final_total
            assert db.execute("SELECT count(*) FROM hadith_fts").fetchone()[0] == final_total
            assert db.execute("SELECT count(*) FROM editorial_translation").fetchone()[0] == sum(
                he_translation_counts.values()
            )
            assert db.execute("SELECT count(*) FROM search_context").fetchone()[0] == sum(int(v) for v in context_counts.values())
            assert db.execute("SELECT count(*) FROM search_token WHERE token='aarisfieldboundaryx'").fetchone()[0] == 0
            assert db.execute("SELECT count(*) FROM search_vocabulary WHERE token='aarisfieldboundaryx'").fetchone()[0] == 0
            assert db.execute("SELECT count(*) FROM search_context WHERE language='hi' AND trim(roman)<>''").fetchone()[0] > 0

            actual = dict(db.execute(
                "SELECT collection_id,COUNT(*) FROM hadith GROUP BY collection_id ORDER BY collection_id"
            ))
            assert actual == expected_all, (actual, expected_all)

            for language, count in he_translation_counts.items():
                installed = db.execute(
                    "SELECT count(DISTINCT t.hadith_id) "
                    "FROM editorial_translation t JOIN hadith h ON h.id=t.hadith_id "
                    "WHERE h.collection_id='hadeethenc' AND t.language=? "
                    "AND t.status IN ('reviewed','released')", (language,)
                ).fetchone()[0]
                assert installed == count, (language, installed, count)

            # Imported translations must never leak onto a core-nine record by inferred text match.
            assert db.execute(
                "SELECT count(*) FROM editorial_translation t JOIN hadith h ON h.id=t.hadith_id "
                "WHERE h.collection_id<>'hadeethenc'"
            ).fetchone()[0] == 0

            for collection_id, count in expected_core.items():
                first = db.execute(
                    "SELECT record_number FROM hadith WHERE collection_id=? "
                    "ORDER BY CAST(record_number AS INTEGER) LIMIT 1",
                    (collection_id,),
                ).fetchone()[0]
                last = db.execute(
                    "SELECT record_number FROM hadith WHERE collection_id=? "
                    "ORDER BY CAST(record_number AS INTEGER) DESC LIMIT 1",
                    (collection_id,),
                ).fetchone()[0]
                assert first == "1"
                assert last == str(count)

            for arabic, expected_hash in db.execute("SELECT arabic,source_sha256 FROM hadith"):
                assert hashlib.sha256(arabic.encode("utf-8")).hexdigest() == expected_hash

            # Independently compare every core-nine installed record with archived vocalized source.
            for cid, meta in inventory["collections"].items():
                plain = plain_records(source_paths(source, meta["local"]))
                installed = dict(db.execute(
                    "SELECT record_number,arabic FROM hadith WHERE collection_id=?", (cid,)
                ))
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
                for hid, number in db.execute(
                    "SELECT id,record_number FROM hadith WHERE collection_id=?", (cid,)
                ):
                    assert hid == f"H:{cid}:{edition}:0:{number}", "Existing record identity changed"

            # HadeethEnc Arabic source identity and its three translations must survive unchanged.
            for hid, source_row in hadeethenc["ar"]["records"].items():
                installed = db.execute(
                    "SELECT arabic FROM hadith WHERE collection_id='hadeethenc' AND record_number=?",
                    (hid,),
                ).fetchone()
                assert installed and installed[0] == source_row["arabic"], ("HadeethEnc drift", hid)
                for language in ("en", "ur", "hi"):
                    upstream = hadeethenc[language]["records"].get(hid)
                    if not upstream:
                        continue
                    if hid in he_withheld[language]:
                        assert db.execute(
                            "SELECT count(*) FROM editorial_translation t JOIN hadith h ON h.id=t.hadith_id "
                            "WHERE h.collection_id='hadeethenc' AND h.record_number=? AND t.language=?",
                            (hid, language)
                        ).fetchone()[0] == 0, ("Withheld translation was installed", language, hid)
                        continue
                    translated = db.execute(
                        "SELECT text FROM editorial_translation t JOIN hadith h ON h.id=t.hadith_id "
                        "WHERE h.collection_id='hadeethenc' AND h.record_number=? AND t.language=? "
                        "AND t.status='released'", (hid, language)
                    ).fetchone()
                    assert translated and translated[0] == upstream["translation"], (
                        "HadeethEnc translation drift", language, hid
                    )

            # Arabic and multilingual translation terms are actually present in the local indexes.
            sample = db.execute(
                "SELECT arabic FROM hadith WHERE collection_id='bukhari' AND record_number='1'"
            ).fetchone()
            token = next((part for part in normalize_arabic(sample[0]).split() if len(part) >= 3), None)
            assert token and db.execute(
                "SELECT count(*) FROM hadith_fts WHERE hadith_fts MATCH ?", (f'"{token}"',)
            ).fetchone()[0] >= 1

            for language in ("en", "ur", "hi"):
                row = db.execute(
                    "SELECT t.hadith_id,t.text FROM editorial_translation t "
                    "WHERE t.language=? AND t.status='released' AND length(t.text)>20 LIMIT 1",
                    (language,)
                ).fetchone()
                assert row
                tokens = list(dict.fromkeys(search_text(row[1]).split()))
                assert tokens
                indexed = db.execute(
                    "SELECT count(*) FROM search_token st JOIN hadith h ON h.rowid=st.hadith_rowid "
                    "WHERE h.id=? AND st.token=?", (row[0], tokens[0])
                ).fetchone()[0]
                assert indexed == 1, ("Translation not indexed", language, row[0], tokens[0])
        finally:
            db.close()

    print(json.dumps({
        "status": "PASS",
        "collections": 10,
        "core_nine_records": core_total,
        "hadeethenc_records": he_count,
        "records": final_total,
        "hadeethenc_translation_records": he_translation_counts,
        "hadeethenc_withheld_translation_ids": he_withheld,
        "hadeethenc_versions": {
            item["language"]: item["version"] for item in hadeethenc_manifest["languages"]
        },
        "generated_diacritics": False,
        "language_coverage": ["ar", "en", "hi", "ur"],
        "runtime_network_required": False,
        "apk_built": False,
    }, indent=2))


if __name__ == "__main__":
    main()
