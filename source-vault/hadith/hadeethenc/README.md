# HadeethEnc translated Hadith source

This lane is for **official HadeethEnc source snapshots only**. It is deliberately separate from
the Open-Hadith-Data core-nine Arabic corpus because HadeethEnc is a curated translated
encyclopedia, not a one-to-one edition of every narration in those nine books.

## Source and use policy

- Provider: https://hadeethenc.com
- Official developer/content policy:
  https://github.com/IslamHouse-API/multilingual-quran-hadith-islamic-content-database-api-hub
- HadeethEnc permits downloading and republication while requiring the original content and
  metadata/source to remain intact and requiring projects to update to newer source versions.
- Aaris therefore exposes only the active current snapshot in builds. Git history is provenance,
  not an alternate selectable "old HadeethEnc edition".
- No HadeethEnc wording may be silently edited and still attributed to HadeethEnc. Any Aaris
  summary/paraphrase must be stored separately and labeled as independent text.

## Acquisition boundary

`tools/acquire_hadeethenc.py` is a maintainer-only network step. Normal content builds and the
Android app never call HadeethEnc. It captures Arabic, English, Urdu and Hindi XLSX files from the
official host, validates HTTPS host/version/XLSX structure, requires at least the reviewed current
versions, and writes SHA-256 metadata transactionally.

The app must not claim a language is installed until the checked-in snapshot has been converted
and its generated SQLite coverage has passed the normal pack integrity checks.


## Cross-language identity gate

The checked-in workbooks are preserved losslessly, but a translated row is installed only when
the Arabic text embedded in that same official language workbook matches the current official
Arabic workbook for the same HadeethEnc id after layout-only normalization. A mismatch is not
auto-corrected, fuzzy-mapped or silently accepted. The row remains in the archived source snapshot
and its id is recorded in the generated manifest's quarantine list.

For the snapshot pinned on 2026-09-25, the installed translation counts are English 2,327,
Urdu 2,098 and Hindi 2,252. These counts may change only when a newer official snapshot is
captured and passes the same verification.
