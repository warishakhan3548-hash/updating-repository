# Aaris Pharmacy

A local-first Flutter inventory and medicine-management app for pharmacy owners,
pharmacists and hospital medicine stores. The app is not a customer shopping or
prescription product.

## Implemented product surface

- One reactive SQLite medicine database; warning, expired, sold, search and
  tracking screens are calculated views rather than copied records.
- Configurable day/month expiry windows, nearest-expiry ordering and progressive
  green-to-red card borders.
- Scoped and global search through typing, microphone, barcode and local OCR,
  including indexed sequence-aware fuzzy matching and confidence labels.
- Manual entry plus reviewed photo, video and text imports. Video uses adaptive
  frame sampling, blur/duplicate filtering and a staging inbox.
- Explicit SOLD/out-of-stock lifecycle, aggregate sale events, period tracking,
  demand-aware reorder suggestions and purchase-order PDF sharing on Android.
- Pharmacy-only AI export/API flows with strict JSON validation, readable diffs,
  explicit approval, stale-review checks, replay protection and atomic apply.
- Existing AI Hub local-model discovery, pinned/resumable GGUF downloads and
  imports, device/context preflight, and evidence-grounded offline scan reasoning.
  See the [Local AI upgrade and verification record](docs/LOCAL_AI_UPGRADE_2026_09_09.md).
- Soft removal, recent activity/Undo, per-medicine version restore and full local
  backup/restore. API keys are stored separately and never enter exports.

Read [the architecture map](docs/ARCHITECTURE.md) and
[implementation status](docs/PROGRESS.md) before changing domain rules.

## Verification policy

`tool/bootstrap.sh` resolves packages and runs analysis/tests only. GitHub
Actions also runs checks only. APK creation and release signing are deliberately
left to the repository owner.
