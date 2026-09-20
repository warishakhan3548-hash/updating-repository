# Quran Integrity Invariants

A release containing Quran text must fail if any applicable invariant fails:

- expected surah set and chosen coordinate set;
- unique ayah/token coordinates;
- approved source SHA-256 matches vault bytes;\n- schema-v2 runtime Quran coordinates and `original_text` match the preserved source row-for-row;\n- derived search lanes recompute from immutable source/display text using the pinned normalization version;
- displayed Arabic comes only from immutable original fields;
- normalized search fields are never used for display;
- token/segment joins are complete for the chosen morphology source;
- gloss/morphology assertions reference existing canonical IDs;
- required source attribution and notices are present and hash-verified;
- source-derived notice/provenance metadata remains bound to the pinned source;
- runtime artifact and notice resolve inside the same immutable directory as their manifest;
- the ayah-only core does not invent token/segment morphology before an approved morphology source exists;
- import is deterministic from the pinned vault snapshot.

Source bytes are never corrected in place. Corrections or interpretive overlays live separately and are attributed.

## Runtime provenance binding

- attribution notices must preserve the pinned source wording and line structure;
- schema-v2 Quran packs bind source URL, attribution, licence/provenance hashes and notice hash back to the Source Vault;
- SQLite `pack_metadata` must carry the same notice and provenance identity as the manifest;
- changing this trust contract requires a new immutable content version rather than rewriting an older pack.
\nA runtime SHA-256 identifies exact shipped bytes. Schema-v2 promotion additionally proves semantic fidelity to Source Vault evidence and the canonical runtime schema; recomputing a hash after altering sacred text or schema must not make a pack valid.\n