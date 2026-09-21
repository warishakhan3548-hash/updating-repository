# Aaris Shield

Aaris Shield is an Android, local-first safety project intended to reduce exposure to sexually explicit content while minimizing false positives on ordinary people and non-sexual contexts.

The repository is developed through small numbered upgrades. The current code is only the architecture foundation; it does **not** yet provide VPN blocking, visual classification, screen observation, blur overlays, OCR filtering, or audio filtering.

## Current verification

Run the focused Step 1 verification without building an APK:

```bash
./tools/verify-foundation.sh
```

See `AARIS_SHIELD_PROGRESS.md` for the authoritative step state and `docs/ARCHITECTURE.md` for architectural boundaries.
