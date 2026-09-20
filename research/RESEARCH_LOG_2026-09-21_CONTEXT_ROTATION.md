# Research Record — Verified Context Rotation — 2026-09-21

Purpose: add a deterministic context-selection policy after the newly landed `rare-word-rescue-v1`, without duplicating enrollment/scheduling logic or manufacturing word identity.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | A 2024 PNAS study found that, across foreign-vocabulary experiments, varied contextual cues during spaced retrieval could outperform constant cues for later memory. | https://pubmed.ncbi.nlm.nih.gov/39453748/ | 2026-09-21 | High | Repeating one sentence forever is not an ideal default; varied contexts are worth testing after initial learning. |
| fact | A 2022 contextual vocabulary study found that both retrieval and informative inference encounters during reading improved retention relative to controls, while retrieval success and context informativeness mattered. | https://pubmed.ncbi.nlm.nih.gov/35436027/ | 2026-09-21 | High | Context choice should remain pedagogical and verified rather than random variation. |
| fact | The repository already stores `review_event.context_ref` and keeps review history append-only. | repository audit at main be39ad1 | 2026-09-21 | High | Context-use/recency can be reconstructed without adding a second learning database. |
| inference | Context rotation should be a separate policy from rare-word enrollment and scheduler due-state. | repository architecture + single-owner rule | 2026-09-21 | High | Add one small selector component rather than modifying or wrapping the new rare-word engine. |
| hypothesis | Familiar verified context is preferable for the first small number of successful reviews before deliberate variation begins. | product hypothesis informed by contextual-learning evidence | 2026-09-21 | Experimental | Keep the two-review familiar phase versioned and replaceable; do not present it as an established optimum. |
| inference | Hadith context must remain opt-in until both the source record and semantic binding are verified. | Evidence Plane / Hadith trust boundary | 2026-09-21 | High | Default to Quran candidates and fail closed on unverified Hadith bindings. |

## Decision

Implement `context-rotation-v1` as a pure local deterministic selector over already-verified candidate bindings.

- It does not decide *whether* to review; `rare-word-rescue-v1`/scheduler owns that.
- It does not discover occurrences or infer lexical identity.
- It prefers familiar verified Quran context during the experimental early phase.
- It later rotates toward least-used and least-recent verified contexts.
- Hadith requires explicit opt-in and a verified binding.
- Equal inputs produce the same output.

## Non-goals

- no new source data;
- no Source Vault promotion;
- no UI activation;
- no random context selection;
- no semantic similarity model;
- no retention-quality claim.
