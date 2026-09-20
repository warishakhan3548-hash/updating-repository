# Reader Architecture

The reader is the first Phase 1 runtime boundary. Its job is intentionally narrow:

> Source Vault → validated content pack → read-only reader projection → UI

It does not own Quran source truth, morphology, search normalization, learning state, networking or AI.

## Display-safety contract

`tools/reader_core.py` opens a content pack only after `tools/pack_gate.py` validates it against the production Source Vault registry.

The reader projection exposes only source-faithful display fields:

- stable Quran coordinate / `ayah_id`;
- `original_text`;
- source assertion identity.

Search-normalized lanes remain internal retrieval data and are not fields on the reader-facing `ReaderAyah` model.

The SQLite connection is opened with `mode=ro&immutable=1` and `PRAGMA query_only = ON`. Content corrections therefore happen through a new verified pack version, never by editing a live reader database.

## Word-tap gate

The current `quran-core 1.0.4` pack is ayah-only.

The reader MUST NOT create tappable words by whitespace-splitting the Quran text. Arabic clitics, orthography and future morphology identity make that an unsafe identity scheme.

Word taps become available only when a future validated pack contains:

1. source-backed `quran_token` rows;
2. an explicit `pack_metadata.quran_token_layer_status = complete` marker;
3. token coverage for every ayah in the pack.

If the marker is absent, token rows must also be absent. The reader returns no word targets rather than fabricating them.

This lets the visible reader ship independently from morphology acquisition while preserving the future semantic-kernel contract.

## UI projection

The eventual Android surface should stay simple:

1. open at the Quran text, not a dashboard;
2. keep Surah/Ayah navigation stable and reversible;
3. render Arabic from `ReaderAyah.original_text` only;
4. use RTL-aware semantics and scalable text;
5. provide at least 48dp accessible touch targets for non-inline controls;
6. when the verified word layer exists, use semantic hit regions around real token identities rather than changing inter-word spacing.

No network request is required on the critical reading path.

## Failure policy

If manifest/source validation, embedded metadata, read-only opening or future token-layer completeness fails, the reader fails closed. It must never fall back to an upstream API, AI-generated Quran text, whitespace tokenization or a search-normalized display string.
