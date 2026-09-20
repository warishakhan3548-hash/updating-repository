# Quran Integrity Invariants

A release containing Quran text must fail if any applicable invariant fails:

- expected surah set and chosen coordinate set;
- unique ayah/token coordinates;
- approved source SHA-256 matches vault bytes;
- displayed Arabic comes only from immutable original fields;
- normalized search fields are never used for display;
- token/segment joins are complete for the chosen morphology source;
- gloss/morphology assertions reference existing canonical IDs;
- required source attribution and notices are present;
- import is deterministic from the pinned vault snapshot;
- every persisted pack manifest points to an artifact that actually exists in a clean clone;
- runtime artifact byte size and SHA-256 match the manifest exactly;
- the ayah-only core does not invent token/segment morphology before a production-approved morphology source exists.

Source bytes are never corrected in place. Corrections or interpretive overlays live separately and are attributed.
