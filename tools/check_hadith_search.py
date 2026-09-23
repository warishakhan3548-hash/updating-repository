#!/usr/bin/env python3
"""Run production reference predicates and Java/Python normalization against local SQLite."""
import argparse
import base64
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time

from build_hadith import search_tokens

ROOT = Path(__file__).resolve().parents[1]


def enc(value):
    return base64.b64encode(value.encode()).decode()


def dec(value):
    return base64.b64decode(value).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--classes", type=Path, required=True)
    args = parser.parse_args()
    java = ["java", "-Xmx256m", "-cp", str(args.classes), "com.aaris.quran.core.SearchIntentChecks"]
    subprocess.run(java, check=True)

    def lookup(db, query):
        plan = subprocess.check_output(java + ["lookup", query], text=True).splitlines()
        return db.execute("SELECT h.collection_id,h.record_number FROM hadith h WHERE " + dec(plan[0]),
                          [dec(value) for value in plan[1:]]).fetchall()

    # Deliberately confusing numbers and a URN: test identity, scope and suffix boundaries.
    fixture = sqlite3.connect(":memory:")
    fixture.executescript("""
      CREATE TABLE hadith(id TEXT,collection_id TEXT,record_number TEXT);
      CREATE TABLE hadith_reference(hadith_id TEXT,scheme TEXT,value TEXT);
      INSERT INTO hadith VALUES
       ('a','bukhari','556'),('b','muslim','556'),('c','muslim','556a'),
       ('d','muslim','556b'),('e','bukhari','5560'),('f','muslim','1');
      INSERT INTO hadith_reference VALUES ('f','sunnah-api-urn-en','556');
    """)
    assert set(lookup(fixture, "5 5 6")) == {("bukhari", "556"), ("muslim", "556"), ("muslim", "556a"), ("muslim", "556b")}
    assert lookup(fixture, "सही बुखारी ५५६") == [("bukhari", "556")]
    assert set(lookup(fixture, "صحيح مسلم ٥٥٦")) == {("muslim", "556"), ("muslim", "556a"), ("muslim", "556b")}
    assert lookup(fixture, "Muslim 556a") == [("muslim", "556a")]
    assert lookup(fixture, "Sahih Muslim 5556") == []
    fixture.close()

    path = ROOT / "app/src/main/assets/hadith.sqlite"
    if not path.is_file():
        print("Reference SQL fixture: PASS; no local corpus available")
        return
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    manifest = json.loads(path.with_name("hadith-manifest.json").read_text())
    if manifest["pack_id"] == "aaris-open-hadith-data-arabic-nine":
        assert len(lookup(db, "556")) == 9
        for query in ["Bukhari 556", "सही बुखारी ५५६", "صحیح بخاری ۵۵۶", "5 5 6 Sahih Bukhari"]:
            assert lookup(db, query) == [("bukhari", "556")]
        assert lookup(db, "Sahih Muslim 5556") == [], "Do not invent missing edition numbers"
    samples = [
        "إِنَّمَا الأَعْمَالُ بِالنِّيَّاتِ", "انما الاعمال بالنيات",
        "ﻻ\u200f تَقْبَلُ", "ﷺ", "٥۵५", "raḥmān", "की क", "نہیں",
        "ه\u08f0ذا", "إلٰهَ", "نص[123] آخر", "اللّهُ\u200d", "ی ک ى ٱ",
    ]
    samples += [row[0] for row in db.execute("SELECT arabic FROM hadith WHERE record_number='1' ORDER BY collection_id")]
    with tempfile.TemporaryDirectory(prefix="aaris-search-") as scratch:
        scratch = Path(scratch)
        source = scratch / "normalization.tsv"
        source.write_text("\n".join(enc(s) for s in samples) + "\n")
        actual = subprocess.check_output(java + ["tokens", str(source)], text=True).splitlines()
        for sample, java_tokens in zip(samples, actual):
            assert search_tokens(sample) == set(dec(java_tokens).split()), ("Normalization drift", sample)
        assert len(actual) == len(samples)

        # Source display is untouched. Both vocalized and plain user text reach the same record.
        row = db.execute("SELECT id FROM hadith WHERE collection_id='bukhari' AND record_number='1'").fetchone()
        if row and manifest["pack_id"] == "aaris-open-hadith-data-arabic-nine":
            for query in ["إِنَّمَا الأَعْمَالُ بِالنِّيَّاتِ", "انما الاعمال بالنيات"]:
                terms = sorted(search_tokens(query))
                marks = ",".join("?" for _ in terms)
                started = time.monotonic()
                candidates = db.execute(
                    "SELECT h.id,h.arabic FROM hadith h WHERE h.collection_id='bukhari' AND h.rowid IN "
                    f"(SELECT hadith_rowid FROM search_token WHERE token IN ({marks}))", terms).fetchall()
                source = scratch / "candidates.tsv"
                source.write_text(enc(query) + "\t" + row[0] + "\n" +
                                  "".join(hid + "\t" + enc(text) + "\n" for hid, text in candidates))
                subprocess.run(java + ["rank", str(source)], check=True)
                print(f"Indexed candidate + JVM check: {time.monotonic()-started:.3f}s (host, not phone benchmark)")
    db.close()
    print("Real Hadith pack: scoped references, suffixes, Unicode digits and vocalized/plain Arabic: PASS")


if __name__ == "__main__":
    main()
