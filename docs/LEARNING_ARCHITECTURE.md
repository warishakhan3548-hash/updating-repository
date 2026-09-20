# Learning Architecture

The Learning Plane helps the reader remember difficult vocabulary without turning Quran reading into a flashcard dashboard.

## Permanent boundary

Durable truth lives in the append-only `exposure_event` and `review_event` ledger in `user.sqlite`. Scheduler memory state is rebuildable. The learning policy must never:

- invent `TokenID`, `LexemeID` or `SenseID`;
- convert a visual whitespace span into a linguistic identity;
- write or alter Evidence Plane Quran/Hadith rows;
- count passive visibility as successful recall;
- serialize one FSRS implementation's equations or private state into permanent event identity.

The current Android reader therefore does **not** invoke this policy yet. It becomes actionable only when a trusted semantic unit from a production-approved gloss/morphology path can be resolved.

## Rare-word rescue v1

Implementation: `app/src/main/java/com/aaris/quran/learning/RareWordRescuePolicy.kt`

Policy version: `rare-word-rescue-v1`.

A word is never prioritized merely because corpus frequency is low. Intervention requires observed personal struggle first. After that gate, the transparent ranking signal is:

```
learning need
= forgetting risk
× exposure scarcity
× personal relevance
```

The three inputs remain separable:

- **forgetting risk** comes from the active scheduler projection; this policy does not implement FSRS formulas;
- **exposure scarcity** estimates how far away the next suitable natural reading encounter is;
- **personal relevance** is user-specific evidence supplied by the caller, not a global frequency label.

Version 1 uses a bounded, deliberately simple scarcity heuristic. A verified encounter immediately ahead has scarcity 0; no known encounter within the configured horizon approaches 1. The default horizon is 24 hours. This heuristic is product policy and must be evaluated before being treated as an efficacy result.

## Natural-exposure substitution

When the scheduler says a personally weak semantic unit is due:

- if a suitable natural Quran encounter is expected within the configured window, prefer that reading encounter;
- otherwise request an explicit review;
- if the scheduler says the item is not due, wait.

A natural encounter is an **opportunity**, not proof of recall. Simply displaying the ayah must not create a successful review event. If the user opens meaning again, that is new difficulty evidence. An explicit retrieval outcome remains a `review_event`.

The first trusted struggle event may use a default 24-hour re-exposure target before a mature scheduler projection exists. This is a configurable bootstrap target, not a scientific claim that 24 hours is universally optimal.

## Context rotation

Review context selection is deterministic and evidence-gated.

Early learning prefers a familiar verified Quran context so the learner can establish meaning with low incidental difficulty. After successful reviews accumulate, selection rotates toward the least-used and least-recent verified contexts instead of repeatedly training one memorized sentence.

Hadith context is opt-in and only eligible after the caller has a verified Hadith record. Unverified contexts are always rejected. Tie-breaking is stable, so identical state produces identical context selection.

This implements a progression of:

```
familiar verified context
→ varied verified Quran contexts
→ verified Hadith contexts when explicitly available/appropriate
```

without physically merging records or weakening source identity.

## Scheduler adapter contract

The policy consumes only scheduler-neutral projections:

- whether the semantic unit is due;
- forgetting risk in the normalized range 0–1.

A future FSRS adapter may compute those values, but another scheduler can replace it without changing the event ledger or policy API. Any scheduler change must be regression-tested by replaying preserved review history.

## Validation boundary

Current JVM tests cover:

- rarity without personal struggle never schedules intervention;
- natural reading can substitute for a due duplicate review;
- distant/unknown exposure produces explicit review;
- scheduler due/not-due remains authoritative;
- the three-factor need formula and deterministic ranking;
- 24-hour bootstrap targeting;
- familiar-context preference early;
- least-used context rotation later;
- rejection of unverified contexts;
- explicit opt-in for verified Hadith context;
- deterministic tie-breaking.

No retention improvement, FSRS benchmark result, low-end-device latency, or production word-tap behavior is claimed by this milestone.
