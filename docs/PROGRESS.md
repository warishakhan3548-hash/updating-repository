# Implementation status — 2026-09-07

## Completed in source

- Master local medicine database with atomic reactive updates and SQLite v3
  migrations for aggregate sales.
- Configurable expiry dashboard, scoped/global type-mic-scan search, progressive
  warning borders, exact-ID editor navigation and fuzzy confidence ranking.
- Manual add/edit/remove/restock, explicit SOLD, aggregate sale recording,
  soft-delete history, latest Undo and per-medicine version restore.
- Reviewed photo/text imports and adaptive local video import with frame sampling,
  bounded decode, blur/duplicate rejection, multi-frame consensus, explicit
  list-row boundaries and temporary-file cleanup.
- Pharmacy-only external-AI TXT/prompt, configurable API route, strict JSON/diff
  review, stale/replay protection, cancellation and atomic selected apply.
- Tracking periods, medicine/stock/salt/form/value metrics, fast movement,
  velocity-aware reorder queue, editable Order Now and native Android PDF share.
- Versioned full backup/restore with strict validation, missing-record archiving,
  typed confirmation and Undo. Secure AI keys are excluded.
- Consistent pharmacy UI across Home, Database, AI, Calculator, Profile, scanner,
  editor, import and backup, with responsive warning cards and shared typography.
- Voice-search lifecycle repair: device locales, permission retry, serialized
  commands, final-word preservation, stale callback rejection and exit cleanup.
- Existing GitHub workflows run source checks and produce an Android release APK.
  The local bootstrap remains a separate check path.

## Verification recorded

- Dart static analysis for `lib` and `test`: clean at source commit `e26e387`.
- Pure-Dart domain contract: 45 checks passed, 0 failed.
- Date-input contract: 24 checks passed, 0 failed.
- Full Flutter/SQLite/widget suite: 123 tests passed in GitHub Actions, including
  11 voice regressions and the narrow-phone/large-text layout check.
- Nine seeded UI screenshots inspected. APK built and uploaded successfully.
  See [research and verification record](DESIGN_RESEARCH_2026_09_07.md) for exact runs.
- Physical Android microphone/camera behavior still needs device acceptance.

## Deliberately outside the local core

- Firebase, cloud sync and external server sync are excluded by product contract.
  Local SQLite plus reviewed backup/restore remain authoritative.
- Optional downloadable local multimodal AI and worldwide catalog providers remain
  extension points, not fake or network-dependent core features.
- Store signing and release hardening remain with the owner. The current generated
  release APK uses the repository's existing debug signing configuration.
