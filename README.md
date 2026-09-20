# Aaris Quran + Hadith Comprehension

A local-first, evidence-first Quran and Hadith comprehension system.

**North star:** Read → get stuck → tap → understand → keep reading.

This repository deliberately begins with the trust foundation before production content or UI. Critical external content is not a runtime/build dependency until its exact legally redistributable artifact is preserved in the project-controlled Source Vault with provenance, licence snapshot and SHA-256.

## Current phase

Phase 0A–0C: Source Vault policy, semantic kernel, canonical schemas, validation gates and research baseline.

Production Quran/Hadith content is currently **not approved**. See `source-vault/registry.json`.

## Architecture boundaries

- `content.sqlite`: replaceable, signed read-only content packs.
- `user.sqlite`: precious local learning history and notes.
- Evidence Plane: immutable source-faithful Quran/Hadith records and attributed assertions.
- Learning Plane: glosses, exposure/review events, scheduler state and derived comprehension.
- AI may expand queries or reason over exported evidence; it cannot author Evidence Plane truth.

Run foundation checks with:

```bash
python -m unittest discover -s tests -v
python tools/vault_gate.py source-vault/registry.json
```
