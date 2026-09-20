# Aaris Quran + Hadith Comprehension

A local-first, evidence-first Quran and Hadith comprehension system.

**North star:** Read → get stuck → tap → understand → keep reading.

This repository builds trust and reproducibility before UI breadth. Critical external content is not a runtime/build dependency until its exact legally redistributable artifact is preserved in the project-controlled Source Vault with provenance, a licence snapshot and integrity checks.

## Current phase

Phase 0A–0C is operational, the canonical Quran layer is published, and Phase 1 has a minimal offline Android reader over the trusted read-only content boundary.

**Production-approved today:** Tanzil Quran Text v1.1, exact pinned Uthmani `txt-2` snapshot.

**Not production-approved yet:** Quranic Arabic Corpus morphology, Hadith datasets, QUL resources and other optional content. See `source-vault/registry.json`.

This is not yet a finished reader application. Reader UI, morphology-assisted word tap, learning, Hadith retrieval and external-AI evidence workflows follow only after their required data foundations pass the same gates.

## Architecture boundaries

- `content.sqlite`: replaceable read-only content packs generated from pinned Source Vault artifacts.
- `user.sqlite`: precious local learning history and notes.
- Evidence Plane: immutable source-faithful Quran/Hadith records and attributed assertions.
- Learning Plane: glosses, exposure/review events, scheduler state and derived comprehension.
- AI may expand queries or reason over exported evidence; it cannot author Evidence Plane truth.
- Normal content builds use project-controlled snapshots, never an uncontrolled upstream `latest`.

## Current Quran core

`tools/quran_core.py` validates the pinned Tanzil artifact and the complete 114-surah / 6,236-ayah coordinate sequence while keeping original display text separate from derived search normalization.

`tools/build_quran_core.py` now builds the current `quran-core` 1.1.0 candidate through the deterministic canonical Quran JSONL layer using manifest schema v3. The pack contains 6,236 ayahs, binds runtime SQLite back to canonical and Source Vault hashes, keeps display Arabic separate from search-normalized lanes, and remains unsigned/candidate until release review and signing. Historical 1.0.4 remains immutable under schema v2.

The ayah-only core intentionally does not manufacture canonical token/morphology identities by whitespace splitting. Word-level morphology waits for a legally preserved, production-approved source.

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
