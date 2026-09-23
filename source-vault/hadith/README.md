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
