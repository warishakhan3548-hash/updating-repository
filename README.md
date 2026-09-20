# Aaris Quran + Hadith Comprehension

A local-first, evidence-first Quran and Hadith comprehension system.

**North star:** Read → get stuck → tap → understand → keep reading.

This repository builds trust and reproducibility before UI breadth. Critical external content is not a runtime/build dependency until its exact legally redistributable artifact is preserved in the project-controlled Source Vault with provenance, a licence snapshot and integrity checks.

## Current phase

Phase 0A–0C is operational, the first Quran evidence source has passed the production Source Vault gate, and Phase 1 has a minimal offline Android reader on the trusted read-only Reader Core boundary. Canonical Quran schema v3 is integrated; its protected publisher will create the next immutable runtime candidate only after exact-tree validation succeeds.

**Production-approved today:** Tanzil Quran Text v1.1, exact pinned Uthmani `txt-2` snapshot.

**Not production-approved yet:** Quranic Arabic Corpus morphology, Hadith datasets, QUL resources and other optional content. See `source-vault/registry.json`.

This is not yet a finished reader application. The current reader deliberately withholds word meanings/morphology because no word-level source has passed the legal Source Vault gate. Learning, Hadith retrieval and external-AI evidence workflows remain later phases.

## Architecture boundaries

- `content.sqlite`: replaceable read-only content packs generated from pinned Source Vault artifacts.
- `user.sqlite`: precious local learning history and notes.
- Evidence Plane: immutable source-faithful Quran/Hadith records and attributed assertions.
- Learning Plane: glosses, exposure/review events, scheduler state and derived comprehension.
- AI may expand queries or reason over exported evidence; it cannot author Evidence Plane truth.
- Normal content builds use project-controlled snapshots, never an uncontrolled upstream `latest`.

## Current Quran core

`tools/quran_core.py` validates the pinned Tanzil artifact and the complete 114-surah / 6,236-ayah coordinate sequence while keeping original display text separate from derived search normalization.

The published `quran-core 1.0.4` remains an immutable schema-v2 candidate. Canonical schema v3 adds a deterministic `canonical/quran-core/1.0.0/ayahs.jsonl` layer between Source Vault evidence and runtime SQLite; the protected publisher targets a new `quran-core 1.1.0` candidate and does not rewrite 1.0.4.

The ayah-only core intentionally does not manufacture canonical token/morphology identities by whitespace splitting. Word-level morphology waits for a legally preserved, production-approved source.

Approved packs require real Ed25519 verification against `policy/trusted_pack_keys.json` after source/provenance/canonical/semantic checks. The production trust policy is intentionally empty, so no current pack can be approved. Android release activation remains separately fail-closed until equivalent on-device signature verification exists.

## Validation

The main branch runs:

```bash
python -m pip install --disable-pip-version-check -r requirements-foundation.txt
python tools/pack_signing.py policy/trusted_pack_keys.json
python tools/vault_gate.py source-vault/registry.json
python tools/pack_gate.py source-vault/registry.json
python tools/validate_schemas.py
python -m unittest discover -s tests -v
```

GitHub Actions executes the same foundation checks on pushes and pull requests. Remote Actions are pinned to full commit SHAs, and the write-capable pack publisher revalidates the exact committed tree before pushing because `GITHUB_TOKEN`-generated pushes do not trigger ordinary push workflows.
