#!/usr/bin/env python3
"""Run production reference predicates and Java/Python normalization against local SQLite."""
import argparse
import base64
import json
import math
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time

from build_hadith import search_tokens, search_text

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
    collections = {row[0] for row in db.execute("SELECT id FROM collection")}
    core_nine = {"bukhari","muslim","nasai","abudawud","tirmidhi","ibnmajah","malik","ahmad","darimi"}
    has_core_nine = core_nine <= collections
    if has_core_nine:
        generic_556 = set(lookup(db, "556"))
        assert {(cid, "556") for cid in core_nine} <= generic_556
        for query in ["Bukhari 556", "sahih bhukhari 556", "bukahri556", "सही बुखारी ५५६",
                      "सही भुखारी ५५६", "सहीह बुखारि ५५६", "صحیح بخاری ۵۵۶",
                      "صحيح البخري ٥٥٦", "5 5 6 Sahih Bukhari"]:
            assert lookup(db, query) == [("bukhari", "556")]
        assert set(lookup(db, "sahih 556")) == {("bukhari", "556"), ("muslim", "556")}
        assert {c for c, _ in lookup(db, "sahih")} == {"bukhari", "muslim"}
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

        def phrase(query):
            plan = subprocess.check_output(java + ["phrase", query], text=True).splitlines()
            where, args = dec(plan[0]), [dec(v) for v in plan[1:]]
            total = db.execute("SELECT count(*) FROM hadith h WHERE " + where, args).fetchone()[0]
            rows = db.execute("SELECT h.id,h.arabic FROM hadith h WHERE " + where +
                              " ORDER BY h.id LIMIT 50", args).fetchall()
            assert len(rows) == min(50, total)
            return total, rows

        if has_core_nine:
            # Exact screenshot query: old OR retrieval fetched 61,313 full records.
            # The actual production plan must now count in the index and load one page only.
            marked_query = "حَدَّثَنَا قُتَيْبَةُ بْنُ سَعِيدٍ حَدَّثَنَا"
            plain_query = "حدثنا قتيبة بن سعيد حدثنا"
            a, b = phrase(marked_query), phrase(plain_query)
            assert a == b and a[0] >= 643, "Screenshot phrase retrieval/normalization regressed"
            assert phrase("حدثنا")[0] >= 57358, "Common words must support indexed pagination"
            assert phrase("Tirmidhi " + plain_query)[0] > 0, "Scoped phrase lost"

            # Execute the same bounded candidate plan used on Android, including bind order.
            query = "حدثنا قتيبه بن سعيد حدثنا"
            terms = sorted(search_tokens(query))
            data = scratch / "candidate-plan.tsv"
            lines = [enc(query)]
            for term in terms:
                df = db.execute("SELECT df FROM search_vocabulary WHERE token=?", (term,)).fetchone()
                weight = max(.25, math.log(1 + manifest["records"] / (1 + (df[0] if df else 0))))
                lines.append(enc(term) + "\t" + str(weight) + ("\t" + enc("قتيبة") if term == "قتيبه" else ""))
            data.write_text("\n".join(lines) + "\n")
            plan = subprocess.check_output(java + ["candidates", str(data)], text=True).splitlines()
            candidates = db.execute("SELECT h.id FROM hadith h WHERE " + dec(plan[0]), [dec(v) for v in plan[1:]]).fetchall()
            assert 0 < len(candidates) <= 1201, "Fuzzy retrieval became an unbounded full-record scan"
            assert any(hid.startswith("H:tirmidhi:") and hid.endswith(":0:1") for (hid,) in candidates)
            print(f"Screenshot phrase: {a[0]} exact matches, 50 rows/page; typo candidates bounded at {len(candidates)}: PASS")

        # Source display is untouched. Both vocalized and plain user text reach the same record.
        row = db.execute("SELECT id FROM hadith WHERE collection_id='bukhari' AND record_number='1'").fetchone()
        if row and has_core_nine:
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

        # Exercise the production exact-phrase lane against checked-in Hindi HadeethEnc text.
        if "hadeethenc" in collections and "hi" in set(manifest.get("language_coverage", [])):
            sample_hi = db.execute(
                "SELECT t.hadith_id,t.text FROM editorial_translation t "
                "JOIN hadith h ON h.id=t.hadith_id "
                "WHERE h.collection_id='hadeethenc' AND t.language='hi' AND t.status='released' "
                "AND length(t.text)>40 LIMIT 1"
            ).fetchone()
            assert sample_hi
            phrase_tokens = search_text(sample_hi[1]).split()[:6]
            assert len(phrase_tokens) >= 3
            total, rows = phrase(" ".join(phrase_tokens))
            assert total > 0 and any(hid == sample_hi[0] for hid, _ in rows), (
                "Hindi HadeethEnc phrase is not reachable through production FTS", sample_hi[0]
            )
            print("Hindi HadeethEnc exact-phrase retrieval: PASS")

            # A remembered Hinglish phrase must also reach trusted Hindi explanation/benefit
            # context without turning that context into displayed Hadith text.
            sample_context = db.execute(
                "SELECT hadith_id,roman FROM search_context "
                "WHERE language='hi' AND kind IN ('explanation','benefits') "
                "AND length(roman)>60 ORDER BY id LIMIT 1"
            ).fetchone()
            assert sample_context
            roman_tokens = search_text(sample_context[1]).split()[:7]
            assert len(roman_tokens) >= 4
            total, rows = phrase(" ".join(roman_tokens))
            assert total > 0 and any(hid == sample_context[0] for hid, _ in rows), (
                "Hinglish meaning context is not reachable through production FTS", sample_context[0]
            )
            print("Hinglish HadeethEnc meaning-context retrieval: PASS")
    db.close()
    print("Real Hadith pack: scoped references, suffixes, Unicode digits and vocalized/plain Arabic: PASS")


if __name__ == "__main__":
    main()
