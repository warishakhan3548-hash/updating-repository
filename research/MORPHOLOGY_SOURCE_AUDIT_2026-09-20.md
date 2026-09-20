# Morphology Source Audit — 2026-09-20

Purpose: identify a legally preservable word-level source for the north-star flow `Read → get stuck → tap → understand → keep reading` without weakening the Source Vault rule.

| Claim | Primary source | Verified | Confidence | Licence implication | Product implication |
|---|---|---:|---|---|---|
| QAC v0.4 download terms identify GNU GPL and allow use in websites/apps with attribution, while prohibiting changes to the distributed annotation file. | https://corpus.quran.com/download/ | 2026-09-20 | High | On its own, this looks redistributable with source-specific conditions. | Technically attractive, but not sufficient for promotion because another official page adds a conflicting restriction. |
| QAC FAQ says downloadable research data is for non-commercial research and also describes the intended final corpus as freely available for non-commercial use under the GNU public license. | https://corpus.quran.com/faq.jsp | 2026-09-20 | High | This conflicts materially with treating GPL text alone as permission for unrestricted commercial redistribution. | Keep `morphology.qac.v0.4` at `awaiting-licence`; do not mirror production bytes until the conflict is resolved by authoritative clarification or permission. |
| QUL exposes downloadable morphology resources for word lemma/root/stem and documents joins by word location. | https://qul.tarteel.ai/docs/tutorial-morphology-end-to-end ; https://qul.tarteel.ai/resources/morphology | 2026-09-20 | High | Technical availability does not itself grant redistribution rights. | QUL is a strong structural candidate for tap-word data and should be evaluated per resource. |
| QUL Word lemma resource 75 exposes a SQLite mapping to `word_location`. | https://qul.tarteel.ai/resources/morphology/75 | 2026-09-20 | High | The inspected page does not state a dataset-specific licence. | Track as metadata-only `awaiting-licence`; do not mirror yet. |
| QUL Word root resource 76 exposes a SQLite mapping to `word_location`. | https://qul.tarteel.ai/resources/morphology/76 | 2026-09-20 | High | The inspected page does not state a dataset-specific licence. | Track as metadata-only `awaiting-licence`; do not mirror yet. |
| QUL FAQ explicitly tells commercial users to check repository and dataset-specific licensing details. | https://qul.tarteel.ai/docs/faq | 2026-09-20 | High | The QUL repository's MIT licence must not be assumed to license all aggregated dataset bytes. | Preserve the per-resource licence firewall; no blanket QUL approval. |

## Decision

No new morphology artifact is production-approved in this audit.

The next legal acquisition step is permission/clarification, not code that downloads or packages these datasets. Until then, the Android reader must continue to render only source-faithful Quran evidence and must not fabricate TokenIDs, roots, lemmas, grammar, or contextual meanings from AI or whitespace heuristics.

## Architecture consequence

The candidate model remains:

`Source Vault artifact → canonical word-location mapping → app-owned TokenID/LexemeID/SenseID → runtime pack`

QUL's `word_location` or QAC coordinates may become source references, but they must never become the only permanent identity in the Semantic Kernel.
