# Research Log

This is a concise decision log, not a substitute for archived source terms or machine-readable provenance. Entries distinguish verified facts from engineering implications and hypotheses.

## 2026-09-20 — QuranEnc Arabic difficult-word glosses

**Verified fact — high confidence.** QuranEnc currently identifies the Arabic “Meanings of Words” resource (`arabic_seraj`, As-Siraj fi Bayan Gharib Al-Quran) as version 1.0.0. Its official API exposes translation metadata with version/update fields and surah-scoped translation retrieval.

**Verified fact — high confidence.** QuranEnc’s official republication terms require source attribution, version identification, preservation without modification/addition/deletion, retention of transcript information, and updating republished material when a newer official version is issued.

**Product implication.** This is a promising source for verse-scoped contextual difficult-word explanations. It is not a morphology authority and must not be used to fabricate TokenID, LexemeID, roots, grammar, or Quran source text.

**Implementation decision.** Add a deterministic staging acquisition tool with pre/post version checks and exact-response hashing. Keep `quran-gloss.quranenc.arabic-seraj.v1.0.0` at `awaiting-artifact` until the exact snapshot and terms bytes have been acquired, reviewed, and preserved under project control.

## 2026-09-20 — HadeethEnc Arabic

**Verified fact — high confidence.** HadeethEnc offers downloadable Arabic material and official republication terms requiring attribution/version preservation and no modification. The official version check observed Arabic v1.7.0 on this date.

**Product implication.** HadeethEnc remains useful for research, but a production Hadith Evidence Plane still needs exact preserved bytes plus collection/edition/numbering provenance and attributed grading semantics.

**Implementation decision.** Keep the source as `research-candidate`; do not build production Hadith search from it yet.

## 2026-09-20 — QUL morphology resources

**Verified fact — high confidence.** QUL exposes word-location keyed lemma/root resources, while its official FAQ directs commercial users to review repository and dataset-specific licensing.

**Product implication.** Technical suitability does not establish redistribution rights.

**Implementation decision.** Keep QUL morphology entries at `awaiting-licence` and mirror no bytes until the exact dataset-specific terms are verified.

## 2026-09-20 — QuranMorph

**Verified fact — high confidence.** The publisher catalogue identifies QuranMorph under CC BY 4.0.

**Known blocker.** The exact artifact has not been acquired through an authorized publisher path, and its published coordinate count still requires alignment review against the project’s 6,236-ayah Quran Evidence Plane.

**Implementation decision.** Keep it at `awaiting-artifact`; do not create canonical morphology identities from unverified bytes.
