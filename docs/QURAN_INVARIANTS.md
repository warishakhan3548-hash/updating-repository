# Quran Integrity Invariants

A release containing Quran text must fail if any applicable invariant fails:

- expected surah set and chosen coordinate set;
- unique ayah/token coordinates;
- approved source SHA-256 matches vault bytes;
- runtime Quran coordinates and `original_text` match the preserved source row-for-row;
- runtime search lanes recompute exactly from immutable source/display text for the pinned normalization version;
- runtime source assertions match the Source Vault identity, version, hash, licence/provenance paths and role;
- displayed Arabic comes only from immutable original fields;
- normalized search fields are never used for display;
- Evidence Plane immutability guards required by the pack schema are present;
- a narrowly scoped pack does not contain unrelated evidence rows that its version did not declare;
- token/segment joins are complete for the chosen morphology source;
- gloss/morphology assertions reference existing canonical IDs;
- required source attribution and notices are present;
- import is deterministic from the pinned vault snapshot.

The release artifact SHA-256 protects the identity of the exact SQLite bytes being shipped. It is not a substitute for semantic verification: the promotion gate independently reconstructs expected Quran rows from the preserved Source Vault artifact and compares the runtime pack row-by-row.

Source bytes are never corrected in place. Corrections or interpretive overlays live separately and are attributed.
