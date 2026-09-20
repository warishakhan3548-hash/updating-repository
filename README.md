# Aaris Quran + Hadith Comprehension

A local-first, evidence-first Quran and Hadith comprehension system.

**North star:** Read → get stuck → tap → understand → keep reading.

This repository builds trust and reproducibility before UI breadth. Critical external content is not a runtime/build dependency until its exact legally redistributable artifact is preserved in the project-controlled Source Vault with provenance, a licence snapshot and integrity checks.

## Current phase

Phase 0A–0C is operational and the first Quran evidence source has passed the production Source Vault gate. A fail-closed, read-only Quran reader projection now starts Phase 1 on top of the deterministic Quran core pack.

**Production-approved today:** Tanzil Quran Text v1.1, exact pinned Uthmani `txt-2` snapshot.

**Not production-approved yet:** Quranic Arabic Corpus morphology, Hadith datasets, QUL resources and other optional content. See `source-vault/registry.json`.

This is not yet a finished Android reader application. The reader data boundary exists, but the visible RTL/accessibility surface, morphology-assisted word tap, learning, Hadith retrieval and external-AI evidence workflows still follow their required trust gates.

## Architecture boundaries

- `content.sqlite`: replaceable read-only content packs generated from pinned Source Vault artifacts.
- `user.sqlite`: precious local learning history and notes.
- Evidence Plane: immutable source-faithful Quran/Hadith records and attributed assertions.
- Learning Plane: glosses, exposure/review events, scheduler state and derived comprehension.
- AI may expand queries or reason over exported evidence; it cannot author Evidence Plane truth.
- Normal content builds use project-controlled snapshots, never an uncontrolled upstream `latest`.

## Current Quran core

`tools/quran_core.py` validates the pinned Tanzil artifact and the complete 114-surah / 6,236-ayah coordinate sequence while keeping original display text separate from derived search normalization.

`tools/build_quran_core.py` deterministically builds the current `quran-core` 1.0.4 candidate under `content-packs/` using provenance-bound manifest schema v2, including SQLite content, manifest and the source-derived Tanzil attribution notice. The pack contains 6,236 ayahs, keeps display Arabic separate from search-normalized lanes, and remains unsigned/candidate until release review and signing. Candidate packs are immutable build outputs and must pass the content-pack gate before promotion.

The ayah-only core intentionally does not manufacture canonical token/morphology identities by whitespace splitting. Word-level morphology waits for a legally preserved, production-approved source.\n\n`tools/reader_core.py` validates the local pack before opening it read-only, exposes only source-faithful `original_text` to the reader surface, provides stable Surah/Ayah navigation, and keeps word taps disabled until a future pack explicitly declares a complete verified token layer.

## Validation

The main branch runs:

```bash
python tools/vault_gate.py source-vault/registry.json
python tools/pack_gate.py source-vault/registry.json
python tools/validate_schemas.py
python -m unittest discover -s tests -v
```

GitHub Actions executes the same foundation checks on pushes and pull requests. Remote Actions are pinned to full commit SHAs, and the write-capable pack publisher revalidates the exact committed tree before pushing because `GITHUB_TOKEN`-generated pushes do not trigger ordinary push workflows.
