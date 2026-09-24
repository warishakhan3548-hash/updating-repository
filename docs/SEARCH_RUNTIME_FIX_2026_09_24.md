# Search stall and spelling fixes — 24 September 2026

Base: `34174d74801fc3f27b1dd54e189c2c454d21f70a`.
Branch: `codex/search-runtime-20260924`.

## Reproduced failures

The screenshot phrase `حَدَّثَنَا قُتَيْبَةُ بْنُ سَعِيدٍ حَدَّثَنَا` selected 61,313 of the
62,169 full narrations through the old OR-token query. Java then normalized and scored every
record before returning anything. Thread interruption alone did not cancel active SQLite queries.
In All mode, Quran initialization and Hadith search also shared one queue and one final callback.

`sahih bhukhari 556` failed because collection aliases were exact-only. `sahih` alone was not a
collection intent, so it could surface an unrelated Quran pronunciation match instead of Hadith books.
The previous tests checked a narrow, prefiltered Bukhari phrase and missed this runtime workload.

## Changes

- Query the FTS phrase index first and count/page in SQLite. The screenshot phrase has 643 exact
  matches; the first page reads 50 full records. The common word `حدثنا` has 57,358 matches but
  still reads only 50 full records per page.
- If no exact phrase exists, use edit-distance spelling candidates and IDF-weighted inverted-index
  selection before loading text. At most 1,201 full records are scored (1,200 candidate budget plus
  an overflow indicator). The UI calls a truncated set the closest matches, not the entire corpus.
  Cached fuzzy results support subsequent pages without rescanning.
- Pass Android CancellationSignal to every Hadith search SQL call. Query edits, navigation and
  destruction cancel both the database work and the worker task. A 20-second deadline cancels
  outstanding jobs and replaces the loading message. Quran and Hadith have independent workers
  and render their results independently; one corpus no longer hides the other's results.
- Recognize bounded spelling differences in standalone collection titles or titles next to a valid
  number, including English, Hindi, Arabic, Urdu, mixed-script prefixes and joined title+number.
  Examples: `sahih bhukhari 556`, `bukahri556`, `muslem 556`, `सही भुखारी ५५६`,
  `सहीह बुखारि ५५६`, `صحيح البخري ٥٥٦`, `صحیح بخری ۵۵۶`.
  Numbers and suffixes are never fuzzily rewritten. Ambiguous fuzzy titles do not silently select
  a book. `sahih`/`सही`/`صحيح` browse Bukhari and Muslim; `sahih 556` searches both.
- Align FTS phrase normalization with the token index and Java query normalization. Builder v6
  rebuilds the index from the same immutable vocalized source. Source Arabic, marks and IDs remain intact.

## Verification

Passed the actual production `HadithStore.java` against the full database using host SQLite/JDBC
with small Android cursor/asset adapters. This exercises the real store constructor, generated SQL,
spelling repair, ranking and pagination rather than reimplementing those algorithms in a test.
The adapter is not an emulator and does not certify Android UI rendering or phone latency.

Observed host times: screenshot phrase 0.131 seconds with marks and 0.106 seconds without;
an Arabic typo query 0.310 seconds. Both phrase variants return identical IDs. The tests verify
actual full-record reads, pagination without duplicates, cached fuzzy paging, source scoping,
missing-number behavior and cancellation followed by a successful request on the same worker.

Also passed: 132 core checks, multilingual reference/normalization checks, actual production
SQL plans on Python SQLite, all 6,236 audio coordinates, 18,708 Quran translation/source mappings,
Quran retrieval regressions, Android resource compilation and native Java compilation.

Commands:

```sh
python3 tools/build_hadith.py --source build/generated/hadith-source
python3 tools/check.py --android-jar /path/to/android-35/android.jar --aapt2 /path/to/aapt2
python3 tools/check_hadith_runtime.py --dependencies /path/to/host-test-jars
```

Host-only dependency versions, download locations and hashes are pinned in
`tools/host-search/dependencies.json`. The verifier does not download them, and they are not app
dependencies. Normal app builds, content and search remain offline.

No APK or CI was run. Physical-phone testing of rapid edits, scope changes and rendering remains
necessary. Hindi/Urdu/English Hadith translations are still absent from this source; recognition
of translated book names does not imply full translated narration search. Muslim 5556 remains
absent from this edition and is never replaced with a different narration.

## Recovery

Inspect git log/status and this branch's PR before resuming. The source data from PR #269 is
already on main; do not reacquire it. Local test logs are in `build/search-runtime/`. Finish
publication only if it has not completed. No credentials or host dependency binaries are committed.
