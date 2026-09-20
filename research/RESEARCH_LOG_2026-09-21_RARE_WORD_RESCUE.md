# Research Record — Rare-word rescue and contextual review — 2026-09-21

Purpose: design a scheduler-neutral learning policy for vocabulary the user has actually struggled with, while keeping the Android UI unchanged until trusted word-level content exists.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | Current FSRS documentation represents memory with Difficulty, Stability and Retrievability, and uses Again/Hard/Good/Easy review grades. | https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm | 2026-09-21 | High | Consume forgetting/due projections through an adapter; do not persist one scheduler's equations as user-data truth. |
| fact | FSRS optimization is based on time-series review logs rather than only a mutable current-state object. | https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-mechanism-of-optimization | 2026-09-21 | High | Keep append-only review history as the durable substrate, matching ADR-018. |
| fact | A 2024 PNAS study across foreign-vocabulary experiments found benefits when spaced retrieval used varied contextual cues rather than repeating the same cue. | https://pubmed.ncbi.nlm.nih.gov/39453748/ | 2026-09-21 | High | Context rotation is worth testing; do not permanently train a semantic unit against one sentence. |
| fact | A 2022 contextualized vocabulary study found that encountering learned foreign words in retrieval or informative inference contexts during reading improved later retention relative to control words. | https://pubmed.ncbi.nlm.nih.gov/35436027/ | 2026-09-21 | High | Natural reading encounters can be treated as review opportunities, but exposure itself must not be logged as successful retrieval. |
| fact | The repository's user schema already distinguishes passive exposure from explicit review outcomes and keeps scheduler state rebuildable. | repository audit at main 00c4d660 | 2026-09-21 | High | Build policy over the existing ledger instead of adding a second memory database or duplicate learning state. |
| inference | Corpus rarity is not sufficient evidence that this user needs deliberate review. | product north star + event model | 2026-09-21 | High | Hard-gate rare-word rescue on observed personal struggle. |
| hypothesis | A transparent score of forgetting risk × exposure scarcity × personal relevance is a useful ordering signal for scarce weak vocabulary. | first-principles synthesis | 2026-09-21 | Medium | Version the heuristic as `rare-word-rescue-v1` and measure it later rather than claiming retention gains now. |
| hypothesis | When a due weak item is predicted to appear naturally soon, using the upcoming reading encounter can reduce duplicate drill pressure without sacrificing the opportunity to retrieve meaning. | contextual-learning evidence + product design | 2026-09-21 | Medium | Add natural-exposure substitution, while requiring explicit outcome evidence before treating memory as strengthened. |

## Decision

Implement a pure, dormant Kotlin domain policy with no new content source and no UI activation:

1. require personal struggle evidence before intervention;
2. rank eligible items with the three-factor learning-need score;
3. leave due/not-due ownership with the scheduler adapter;
4. prefer a verified natural Quran encounter when it falls inside the configured review window;
5. otherwise request an explicit review;
6. rotate contexts deterministically from familiar to varied verified contexts;
7. require explicit opt-in plus verification before Hadith contexts may participate.

## Non-goals

- no Quran tokenization or lexeme inference from whitespace;
- no word-tap UI activation;
- no FSRS parameter tuning;
- no new database or user-schema migration;
- no Hadith/Quran/gloss/morphology source bytes;
- no claim that the 24-hour bootstrap target is optimal;
- no retention-performance claim before a labelled learning evaluation exists.

This milestone strengthens hidden learning intelligence while preserving the visible product principle: read first, learn only when needed.
