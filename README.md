# Aaris Quran + Hadith Comprehension

A local-first, evidence-first Quran and Hadith comprehension system.

**North star:** Read → get stuck → tap → understand → keep reading.

This repository builds trust and reproducibility before UI breadth. Critical external content is not a runtime/build dependency until its exact legally redistributable artifact is preserved in the project-controlled Source Vault with provenance, a licence snapshot and integrity checks.

## Current phase

Phase 0A–0C is operational and Phase 1 has a minimal offline Android reader on the trusted read-only Reader Core boundary. The reader also has a strict ayah-level offline Quran search lane over the existing provenance-bound search fields; it adds no new evidence source and never renders normalized text.

**Production-approved source today:** Tanzil Quran Text v1.1, exact pinned Uthmani `txt-2` snapshot.

**Current Quran runtime candidate:** `quran-core 1.1.0` (manifest schema v3), generated from the project-controlled Tanzil snapshot through the deterministic canonical Quran JSONL layer. It contains 6,236 ayahs and remains `candidate` / unsigned.

**Not production-approved yet:** QuranEnc Arabic difficult-word glosses, Quranic Arabic Corpus/QuranMorph/QUL morphology, Hadith datasets and other optional content. See `source-vault/registry.json`.

The reader is intentionally narrow: source-faithful Arabic, local navigation, strict local ayah search and safe UI-only tap anchors. Morphology-assisted word tap, learning, Hadith retrieval and external-AI evidence workflows follow only after their required data foundations pass the same gates.

## Architecture boundaries

- `content.sqlite`: replaceable read-only content packs generated from pinned Source Vault artifacts.
- `user.sqlite`: precious local learning history and notes.
- Evidence Plane: immutable source-faithful Quran/Hadith records and attributed assertions.
- Learning Plane: glosses, exposure/review events, scheduler state and derived comprehension.
- Canonical Quran JSONL: long-lived semantic reproducibility anchor between Source Vault and SQLite runtime bytes.
- AI may expand queries or reason over exported evidence; it cannot author Evidence Plane truth.
- Normal content builds use project-controlled snapshots, never an uncontrolled upstream `latest`.
- Release approval is fail-closed: approved manifests require a signed positive `release_sequence` and must pass the authoritative pack gate plus project-controlled Ed25519 trust policy.

## Current Quran core

`tools/quran_core.py` validates the pinned Tanzil artifact and the complete 114-surah / 6,236-ayah coordinate sequence while keeping original display text separate from derived search normalization.

`tools/build_quran_canonical.py` creates `canonical/quran-core/1.0.0/ayahs.jsonl`, whose SHA-256 is the durable semantic anchor. `tools/build_quran_core.py` then builds `content-packs/quran-core/1.1.0/content.sqlite` from that canonical layer using manifest schema v3.

The Android debug reader bundles this 1.1.0 candidate directly. Release builds remain blocked because the current trust root is still `bootstrap-required` and the pack is not approved/signed. No private release key is stored in GitHub.

The ayah-only core intentionally does not manufacture canonical token/morphology identities by whitespace splitting. Word-level linguistic identities wait for a legally preserved, production-approved source.

## Validation

The main branch runs:

```bash
python -m pip install --disable-pip-version-check -r requirements-ci.txt
python tools/vault_gate.py source-vault/registry.json
python tools/pack_gate.py source-vault/registry.json
python tools/validate_schemas.py
python -m unittest discover -s tests -v
```

GitHub Actions executes the same foundation checks on pushes and pull requests. Remote Actions are pinned to full commit SHAs, and the write-capable pack publisher revalidates the exact committed tree before pushing because `GITHUB_TOKEN`-generated pushes do not trigger ordinary push workflows.
