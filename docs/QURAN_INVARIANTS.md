# Quran Integrity Invariants

A release containing Quran text must fail if any applicable invariant fails:

- expected surah set and chosen coordinate set;
- unique ayah/token coordinates;
- approved source SHA-256 matches vault bytes;
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
