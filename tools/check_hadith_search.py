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

from build_hadith import search_tokens, search_text, romanize_hindi, SEARCH_FIELD_BOUNDARY

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

        hindi_samples = [
            row[0] for row in db.execute(
                "SELECT text FROM editorial_translation WHERE language='hi' AND status='released' "
                "ORDER BY hadith_id LIMIT 120"
            )
        ]
        hindi_samples += [
            row[0] for row in db.execute(
                "SELECT text FROM search_context WHERE language='hi' ORDER BY id LIMIT 120"
            )
        ]
        if hindi_samples:
            roman_source = scratch / "hindi-romanization.tsv"
            roman_source.write_text("\n".join(enc(value) for value in hindi_samples) + "\n")
            java_roman = subprocess.check_output(java + ["romanize", str(roman_source)], text=True).splitlines()
            assert len(java_roman) == len(hindi_samples)
            for source_text, encoded_roman in zip(hindi_samples, java_roman):
                assert romanize_hindi(source_text) == dec(encoded_roman), ("Hindi romanization drift", source_text)
            print(f"Hindi build/runtime romanization parity: {len(hindi_samples)} real source rows PASS")

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

            layered_id = db.execute(
                "SELECT hadith_id FROM editorial_translation GROUP BY hadith_id HAVING count(*)>=2 ORDER BY hadith_id LIMIT 1"
            ).fetchone()[0]
            layered_texts = [
                search_text(row[0]) for row in db.execute(
                    "SELECT text FROM editorial_translation WHERE hadith_id=? AND status='released' ORDER BY rowid",
                    (layered_id,)
                ) if search_text(row[0])
            ]
            assert len(layered_texts) >= 2
            fts_latin = db.execute("SELECT latin FROM hadith_fts WHERE hadith_id=?", (layered_id,)).fetchone()[0]
            assert (layered_texts[0] + " " + SEARCH_FIELD_BOUNDARY + " " + layered_texts[1]) in fts_latin, (
                "Evidence fields lost their phrase boundary", layered_id
            )
            assert db.execute(
                "SELECT count(*) FROM search_token WHERE token=?", (SEARCH_FIELD_BOUNDARY,)
            ).fetchone()[0] == 0
            print("Cross-field exact-phrase boundary: PASS")

            hindi_roman = romanize_hindi(sample_hi[1])
            hindi_roman_tokens = search_text(hindi_roman).split()[:7]
            assert len(hindi_roman_tokens) >= 4
            total, rows = phrase(" ".join(hindi_roman_tokens))
            assert total > 0 and any(hid == sample_hi[0] for hid, _ in rows), (
                "Official Hindi Hadith translation is not reachable through its Hinglish shadow", sample_hi[0]
            )
            print("Hinglish shadow of official Hindi Hadith translation: PASS")

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

            def candidate_ids(query):
                terms = sorted(search_tokens(query))
                data = scratch / "remembered-candidate-plan.tsv"
                lines = [enc(query)]
                for term in terms:
                    found = db.execute("SELECT df FROM search_vocabulary WHERE token=?", (term,)).fetchone()
                    weight = max(.25, math.log(1 + manifest["records"] / (1 + (found[0] if found else 0))))
                    lines.append(enc(term) + "\t" + str(weight))
                data.write_text("\n".join(lines) + "\n")
                plan = subprocess.check_output(java + ["candidates", str(data)], text=True).splitlines()
                return {
                    row[0] for row in db.execute(
                        "SELECT h.id FROM hadith h WHERE " + dec(plan[0]),
                        [dec(v) for v in plan[1:]]
                    )
                }

            # User-style question scaffolding must not crowd the evidence out of the bounded
            # candidate set. HadeethEnc 3293 explicitly explains two rak'ahs distinct from the
            # obligatory prayer followed by the istikhara supplication.
            remembered_hi = "ये कहाँ पर लिखा है कि दो रकात नमाज फर्ज के बाद दुआ करनी है"
            remembered_hinglish = "ye kaha likha hai ki do rakat namaz farz ke bad dua karni hai"
            assert "H:hadeethenc:official:3293" in candidate_ids(remembered_hi)
            assert "H:hadeethenc:official:3293" in candidate_ids(remembered_hinglish)
            print("Hindi/Hinglish remembered-question candidate retrieval: PASS")

            # User-story regression: identify a real HadeethEnc record whose indexed trusted
            # evidence mentions both the Prophet and ablution, then reach it from Hindi/Hinglish
            # remembered wording without requiring the display language to match the query.
            wudu_target = db.execute(
                "SELECT h.id FROM hadith h "
                "JOIN search_token p ON p.hadith_rowid=h.rowid AND p.token='prophet' "
                "JOIN search_token a ON a.hadith_rowid=h.rowid AND a.token='ablution' "
                "WHERE h.collection_id='hadeethenc' ORDER BY h.rowid LIMIT 1"
            ).fetchone()
            assert wudu_target, "Pinned trusted corpus unexpectedly has no Prophet+ablution evidence"
            story_hi = "एक बार एक सहाबी ने नबी को वुज़ू करते देखा"
            story_hinglish = "ek baar ek sahabi ne nabi ko wuzu karte dekha"
            assert wudu_target[0] in candidate_ids(story_hi), ("Hindi remembered wudu story lost", wudu_target[0])
            assert wudu_target[0] in candidate_ids(story_hinglish), ("Hinglish remembered wudu story lost", wudu_target[0])
            print("Real Hindi/Hinglish remembered wudu-story retrieval: PASS")
    db.close()
    print("Real Hadith pack: scoped references, suffixes, Unicode digits and vocalized/plain Arabic: PASS")


if __name__ == "__main__":
    main()
