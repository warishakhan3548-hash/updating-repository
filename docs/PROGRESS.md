# Implementation status — 2026-09-07

## Completed in source

- Master local medicine database with atomic reactive updates and SQLite v3
  migrations for aggregate sales.
- Configurable expiry dashboard, scoped/global type-mic-scan search, progressive
  warning borders, exact-ID editor navigation and fuzzy confidence ranking.
- Manual add/edit/remove/restock, explicit SOLD, aggregate sale recording,
  soft-delete history, latest Undo and per-medicine version restore.
- Reviewed photo/text imports and adaptive local video import with frame sampling,
  blur/duplicate rejection, multi-frame consensus and temporary-file cleanup.
- Pharmacy-only external-AI TXT/prompt, configurable API route, strict JSON/diff
  review, stale/replay protection, cancellation and atomic selected apply.
- Tracking periods, medicine/stock/salt/form/value metrics, fast movement,
  velocity-aware reorder queue, editable Order Now and native Android PDF share.
- Versioned full backup/restore with strict validation, missing-record archiving,
  typed confirmation and Undo. Secure AI keys are excluded.
- GitHub and local bootstrap explicitly run checks only; APK build/upload steps
  have been removed.

## Verification recorded

- Dart static analysis for `lib` and `test`: clean after final hardening.
- Pure-Dart domain contract: 45 checks passed, 0 failed.
- Full Flutter/SQLite/widget suite is configured in GitHub Actions without any APK
  build. Android hardware behaviors cannot be proven in the current container.

## Deliberately configuration-dependent or future

- Firebase backup/multi-device sync needs the owner’s Firebase project, platform
  configuration and an explicit conflict policy. Local backup/restore is complete;
  core runtime has no cloud dependency.
- Optional downloadable local multimodal AI and worldwide catalog providers remain
  extension points, not fake or network-dependent core features.
- Store signing, release hardening and APK generation remain with the owner.
