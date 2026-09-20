# Quran Integrity Invariants

A release containing Quran text must fail if any applicable invariant fails:

- expected surah set and chosen coordinate set;
- unique ayah/token coordinates;
- approved source SHA-256 matches vault bytes;\n- runtime Quran coordinates and `original_text` match the preserved source row-for-row;\n- runtime search lanes recompute exactly from immutable source/display text for the pinned normalization version;\n- runtime source assertion, attribution, source URL and notice are reconstructed from preserved Source Vault evidence;
- displayed Arabic comes only from immutable original fields;
- normalized search fields are never used for display;
- token/segment joins are complete for the chosen morphology source;
- gloss/morphology assertions reference existing canonical IDs;
- required source attribution and notices are present and hash-verified;
- source-derived notice/provenance metadata remains bound to the pinned source;
- runtime artifact and notice resolve inside the same immutable directory as their manifest;
- the ayah-only core does not invent token/segment morphology before an approved morphology source exists;
- import is deterministic from the pinned vault snapshot;\n- runtime SQLite schema matches the reviewed canonical schema and contains no undeclared morphology/Hadith evidence.

The runtime artifact SHA-256 identifies exact shipped bytes, while semantic verification independently proves those bytes still represent the preserved sacred source. Both gates are required.\n\nSource bytes are never corrected in place. Corrections or interpretive overlays live separately and are attributed.
