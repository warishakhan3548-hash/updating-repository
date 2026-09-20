# Research audit — QuranEnc preserved snapshot and multi-file Source Vault

Verified: 2026-09-21

This record separates observed source facts from project inferences. It is not legal advice.

| Claim | Source | Classification | Confidence | Licence / product implication |
|---|---|---|---|---|
| QuranEnc publishes an Arabic "Meanings of Words" resource identified as As-Siraj / `arabic_seraj`, with the inspected current resource version V1.0.0. | https://quranenc.com/en/home and https://quranenc.com/en/browse/arabic_seraj | verified fact | high | The preserved review snapshot can be bound to a named source/version rather than an unversioned "latest". |
| QuranEnc's published republication conditions require, among other things, no modification, source/publisher attribution, version identification, and updating redistributed material according to the latest version issued. | https://quranenc.com/en/home/about/terms-and-conditions | verified fact | high | Current-version freshness and immutable historical retention must be treated as separate release questions. |
| The inspected QuranEnc terms do not clearly state that superseded versions may remain indefinitely in a public immutable downstream archive. | same terms snapshot + current official terms | architectural/legal-risk inference | medium-high | Keep `historical_snapshot_retention_status: unresolved`; do not promote the source until explicit permission or a legally compatible preservation design is verified. |
| The project already preserves the exact v1.0.0 review capture as official source/index and terms pages, provenance, one API-set manifest, and 114 exact Surah API responses covering 6,236 coordinates. | project Source Vault at `source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0/` | verified repository fact | high | Do not recapture or create a second ingestion format. Verify the preserved bytes offline instead. |
| A multi-file upstream release can be preserved without concatenating or rewriting source bytes by using a project-controlled SHA-256 ledger as the artifact root. | first-principles integrity design; implemented in `tools/vault_gate.py` | architectural inference | high | Adds a reusable Source Vault primitive while keeping source-specific semantics outside the generic gate. |
| Quranic Arabic Corpus v0.4 official materials still present a licensing tension: the download page presents GPL/verbatim-copy terms while the official FAQ describes non-commercial research use. | https://corpus.quran.com/download/ and https://corpus.quran.com/faq.jsp | verified fact | high | QAC remains blocked from production pending clarification; no artifact promotion. |
| QUL morphology resources are technically useful but resource-specific licensing still requires independent review for commercial use. | https://qul.tarteel.ai/resources and QUL FAQ | verified fact | high | Keep QUL morphology metadata-only until a specific dataset's redistribution/modification terms are established. |

## Product implication

The highest-value change in this run is trust hardening rather than feature expansion. The preserved QuranEnc bytes are useful for future tap-to-understand work, but they should first become mechanically re-verifiable and legally promotable. Until then, the Android reader must continue to render Quran from the existing trusted Tanzil Evidence Plane and must not expose QuranEnc glosses as production content.

The source snapshot verifier is intentionally network-free. A clean clone can validate the exact preserved candidate without QuranEnc being online, and normal builds do not mutate or refresh the capture.
