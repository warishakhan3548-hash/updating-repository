# Offline Hadith content architecture

## Goal

Aaris should be able to browse and search Hadith with **zero runtime network dependency**.
The app must not need Sunnah.com or any other website once a content pack has been installed
or bundled. Quran and Hadith remain immutable source content; user notes, bookmarks and recall
history stay in the separate learning database.

The catalog in `tools/hadith-catalog.json` mirrors the collection names currently exposed on
Sunnah.com's homepage as a planning target. It is metadata only, not copied Hadith text.

## Source acquisition rule

Do **not** scrape or mass-copy Sunnah.com. Their published About page says they do not permit
scraping or mass reproduction of entire books/collections. Their developer page points developers
to the API and mentions an offline dump, but currently says that dump is not available yet.

A local Aaris pack therefore accepts only a source with explicit redistribution permission for the
specific text being imported. Arabic text, translations, grades and commentary each keep separate
provenance because permission for one layer does not automatically cover the others.

Third-party repositories that themselves scraped Sunnah.com are not treated as a rights clearance
merely because their code repository has an open-source license.

## Storage model

Do not merge Hadith into the Quran pack. Generate a separate immutable database:

```
source-vault/hadith/<pack-id>/
  manifest.json
  collections/*.jsonl
  LICENSES/*

tools/build_hadith.py
        |
        v
app/src/main/assets/hadith.sqlite
```

The manifest is the source of truth and must include a pack id/version, source name/version,
redistribution statement, license files, and SHA-256 for every imported file.

## Stable identity

A Hadith identity is edition-aware. Never assume the same printed/reference number means the same
record across editions.

Recommended canonical form:

```
H:<collection>:<edition>:<book>:<record>
```

Examples:

```
H:bukhari:<edition>:1:1
H:muslim:<edition>:1:1
```

Alternative numbering schemes belong in alias/reference tables, not in the primary key.

## Database schema

The generated pack uses separate tables for:

- `collection`: catalog and edition metadata.
- `book` and `chapter`: hierarchical navigation.
- `hadith`: immutable Arabic/source text plus optional licensed translations.
- `hadith_reference`: alternate numbering/reference schemes.
- `grade_assertion`: grade, grader and source/version; grades are attributed, never invented.
- `provenance`: source hashes, licenses, pack id and builder version.

Search-normalized shadows may be generated for retrieval, but display text is never silently
rewritten.

## Editorial / translation control

Aaris may have its own editable translation or explanation layer, but it must be stored separately
from imported source text:

```
canonical source text      -> immutable
licensed source translation -> immutable
Aaris-authored translation  -> independently versioned/editable
Aaris notes/explanation     -> independently versioned/editable
```

This allows corrections and editorial work without altering the underlying Arabic record or
misrepresenting an upstream translation.

## Packaging

For small packs, source files may live directly in Git. Large source archives should use Git LFS or
a versioned release asset, while the manifest/hash file remains in normal Git. The Android APK
should bundle a generated `hadith.sqlite` when size is acceptable; otherwise the same verified
pack format can support a one-time in-app import/download later without changing record identities.

## Migration stages

1. **Catalog (done):** map every current Sunnah.com top-level collection target.
2. **Importer (done):** deterministic JSONL -> SQLite builder with strict provenance and license hash checks.
3. **Official acquisition path (done in code):** resumable Sunnah API client that writes a self-contained source vault; it requires an operator-supplied API key and redistribution/offline permission evidence.
4. **Source acquisition (external prerequisite):** obtain the permission/API access and run the importer. No corpus is claimed before this succeeds.
5. **Validation (done in code):** source hashes, Arabic text hashes, duplicate IDs, foreign keys, record/collection counts, full-catalog gate and a synthetic builder regression.
6. **Android store/UI (done in code):** read-only checksum-verified `HadithStore`, Collection -> Book -> Chapter -> Hadith navigation, pagination and local Arabic/English/reference search; no web fallback.
7. **Evidence/recall (later):** integrate only after the real record identities and source versions are frozen.

Until stage 3 has valid source files, Aaris must not claim that a Hadith collection is installed.
