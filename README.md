# Aaris Shield

Aaris Shield is an Android, local-first safety project intended to reduce exposure to sexually explicit content while minimizing false positives on ordinary people and non-sexual contexts.

The repository is developed through small numbered upgrades. Step 2 adds a local DNS/domain shield. Step 3 adds a bounded, on-device visual safety classifier with explicit safe/ambiguous/unsafe states. Region localization, screen observation, blur overlays, OCR filtering, and audio filtering are not implemented yet.

The network layer is deliberately narrow: it blocks reviewed domains locally and does not inspect TLS traffic. Apps using their own encrypted DNS can bypass this layer, so the project does not claim universal pre-render blocking.

The visual layer packages a pinned Yahoo OpenNSFW-compatible TensorFlow Lite model at build time, verifies its immutable Git blob identity, and performs inference locally at runtime. Model or inference failures become ambiguous rather than safe. This step does not capture screens or claim that arbitrary third-party content can be intercepted before rendering.

## Focused verification

Run the Android-free focused checks without building an APK:

```bash
./tools/verify-network.sh
./tools/verify-visual.sh
```

CI runs foundation/network/visual unit tests, verifies the pinned model asset, and compiles app Kotlin. Full APK assembly remains reserved for Step 18.

See `AARIS_SHIELD_PROGRESS.md` for authoritative step state and `docs/ARCHITECTURE.md` for architectural boundaries and known limits.
