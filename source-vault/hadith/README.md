# Hadith source vault

This directory is the only accepted input location for Aaris offline Hadith source packs.

## Active pack

A build becomes Hadith-enabled only when this file exists:

`source-vault/hadith/active/manifest.json`

The active pack must contain local source files, permission/license evidence and exact SHA-256
hashes. `tools/build_hadith.py` performs no network access and refuses an empty pack, missing
license evidence, changed source bytes, duplicate IDs or broken references.

The Android build then creates two generated assets:

- `app/src/main/assets/hadith.sqlite`
- `app/src/main/assets/hadith-manifest.json`

Those generated assets are checksum-verified again on the phone before the database is opened
read-only.

## Content target

`tools/hadith-catalog.json` records the current full top-level Sunnah.com collection catalog as a
coverage target. A catalog entry is not considered installed until actual source records for that
edition are present in the verified pack.

## Editing policy

Never overwrite imported Arabic/source text to make a correction. Add a new source edition/version,
or put Aaris-authored translation/explanation in a separate editable layer. Grades remain attributed
assertions with grader and source version.

## JSONL record types

A source pack may split records across many `.jsonl` files. Supported records are
`collection`, `book`, `chapter` and `hadith`. See `manifest.example.json` and
`records.example.jsonl` for the minimum shape.

Large licensed source archives should be kept with a pinned checksum using Git LFS or an immutable
release asset rather than silently downloaded during the app build.


## Official Sunnah.com API acquisition

Aaris includes `tools/acquire_sunnah_api.py` for a **one-time source-vault import** through
Sunnah.com's documented API. It is deliberately not a website scraper.

The importer requires:

1. an API key in the `SUNNAH_API_KEY` environment variable;
2. a local file containing the applicable redistribution/offline permission or license evidence;
3. a factual `--redistribution-basis` description.

Example:

```sh
export SUNNAH_API_KEY='...'
python3 tools/acquire_sunnah_api.py \
  --permission-file /private/path/SUNNAH_PERMISSION.txt \
  --redistribution-basis 'Written permission for an offline Aaris snapshot'
```

The key is never written to the repository. Raw API responses are retained under
`active/raw/`, normalized source records are split by collection under `active/records/`,
all bytes are SHA-256 locked, and only then is `active/manifest.json` finalized.

By default the acquisition refuses to finalize unless the API exposes every title in
`tools/hadith-catalog.json`. `--allow-partial-catalog` exists only for development and a partial
pack must never be described as the full Aaris Hadith library.

The next Android build deterministically generates `hadith.sqlite` from the source vault. Runtime
reading/search remains completely offline.
