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
- schema-v2 runtime packs carry a pack-local notice and the same notice/provenance identity inside SQLite metadata;
- notice bytes are derived from the pinned source artifact rather than rewritten by the importer;
- import is deterministic from the pinned vault snapshot.

Source bytes are never corrected in place. Corrections or interpretive overlays live separately and are attributed.
