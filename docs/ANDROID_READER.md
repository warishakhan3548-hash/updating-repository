# Android Reader — Phase 1 projection

The Android reader is a platform projection of the canonical Reader Core contract in `tools/reader_core.py` and `docs/READER_ARCHITECTURE.md`. It is not a second semantic engine and it does not own Quran identities, morphology, lexemes, meanings, or search normalization.

## Trust path

`Source Vault -> deterministic importer -> pack gate -> quran-core -> Reader Core contract -> Android adapter -> UI`

The current development build packages `quran-core` 1.0.4 from the project-controlled repository. That pack is still `candidate` and unsigned, so it is included in the Android **debug** source set only.

The Android adapter independently fails closed on the same immutable facts that bind manifest schema v2 to Source Vault:

- source ID and version;
- source SHA-256;
- source licence SHA-256;
- source provenance SHA-256;
- runtime SQLite SHA-256;
- source-derived notice SHA-256;
- 6,236-record contract.

The copied database is opened with Android SQLite `OPEN_READONLY`. Display queries project only `ayah_id`, `surah`, `ayah`, and `original_text`. Search-normalized columns are not part of the rendering model.

## Candidate / release boundary

Debug builds may exercise the current candidate pack so UI work can proceed.

Non-debug runtime code refuses a pack whose `review_status` is not `approved`, matching the canonical Reader Core production guard. In addition, the candidate pack is not placed in the release source set at all.

These development pins are not a replacement for the future signed content activation/update chain. A production Quran release remains blocked until the pack review/signing policy is satisfied.

## Visible experience

The Phase 1 screen stays deliberately small:

- Quran title;
- Previous / current Surah / Next;
- vertically scrolling source-faithful Arabic;
- unobtrusive Tanzil attribution.

Arabic text is rendered RTL, system font scaling remains active, and standard Material controls provide accessible semantics/touch behavior.

## Word tap boundary

The repository Reader Core already permits transient `SurfaceTapAnchor` spans for UI hit testing. Those spans are explicitly non-canonical and carry no TokenID, LexemeID, root, lemma, gloss, or grammar claim.

The Android reader therefore does not fabricate a word-by-word meaning layer from whitespace. Tap-to-understand should become visible only when a legally preserved, provenance-backed word/gloss source can resolve a surface anchor to trusted content.

## Privacy and network

The app manifest requests no Internet, location, account, analytics, or advertising permission. Quran reading uses only the local project-controlled content pack. Opening the Tanzil attribution link delegates to an external browser through an explicit user tap; there is no network dependency on the critical reading path.
