# Aaris Shield

Aaris Shield is an Android, local-first safety project intended to reduce exposure to sexually explicit content while minimizing false positives on ordinary people and non-sexual contexts.

The repository is developed through small numbered upgrades. Step 2 adds a local DNS/domain shield; visual classification, screen observation, blur overlays, OCR filtering, and audio filtering are not implemented yet.

The network layer is deliberately narrow: it blocks reviewed domains locally and does not inspect TLS traffic. Apps using their own encrypted DNS can bypass this layer, so the project does not claim universal pre-render blocking.

## Focused verification

Run the Android-free DNS policy/packet checks without building an APK:

```bash
./tools/verify-network.sh
```

CI additionally runs `:core:foundation` tests, `:core:network` tests, and `:app:compileDebugKotlin`. Full APK assembly remains reserved for Step 18.

See `AARIS_SHIELD_PROGRESS.md` for authoritative step state and `docs/ARCHITECTURE.md` for architectural boundaries and known limits.
