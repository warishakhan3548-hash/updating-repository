# Learning Policy — Rare-Word Rescue v1

The reader remains primary. Learning intelligence should reduce interruptions, not turn Quran reading into a flashcard dashboard.

## Purpose

Frequent items may reappear naturally during reading. A personally difficult item can instead disappear for a long time. The rescue policy therefore considers three separate signals:

```
learning need ≈ forgetting risk × exposure scarcity × personal relevance
```

This is a ranking model, not a claim of a universally optimal cognitive formula.

- **Forgetting risk** comes only from a scheduler projection when retrievability is actually available. The policy does not invent a risk value when it is unknown.
- **Exposure scarcity** is derived from the number of suitable predicted natural encounters in the near reading path.
- **Personal relevance** comes from preserved evidence of struggle, not corpus rarity alone.

A semantic unit is not enrolled merely because it is globally rare.

## Enrollment evidence

The v1 policy treats these as current struggle evidence:

- an explicit unknown mark;
- an Again review;
- a Hard review;
- repeated quick-meaning openings reaching the versioned policy threshold.

One quick peek alone does not enroll a unit. Passive visibility never counts as recall success.

Existing scheduler enrollment or a scheduler-due review may also keep a semantic unit in the rescue pool, but scheduler state remains a rebuildable projection over durable user history.

## Natural-exposure substitution

A future verified occurrence graph may predict that the same semantic unit will appear soon in the user's reading path.

When an explicit scheduler review is due, natural reading may substitute for that interruption only when:

1. at least one suitable natural encounter is predicted soon; and
2. the active scheduler adapter explicitly authorizes deferral to that encounter.

If a scheduler review is due and that authorization is absent or false, v1 fails closed to an explicit review.

Retrievability may still be supplied for ranking and diagnostics, but the rescue policy does not hard-code one global retrievability floor. FSRS-style schedulers can use different desired-retention targets, so the adapter—not this product heuristic—owns the decision about whether delaying a due review is acceptable.

For a newly observed struggle that is not yet an overdue scheduler item, an imminent natural encounter may be allowed to carry the next opportunity without inventing scheduler evidence.

**Important:** choosing `NATURAL_EXPOSURE` only changes *where the next opportunity happens*. It does not record a successful review. Passive reading stays an exposure event. A later explicit retrieval result is what may update scheduler memory evidence.

## Trust boundary

`RareWordRescuePolicy` accepts an existing app-owned `semanticUnitId`. It does not create TokenID, LexemeID, SenseID, roots, lemmas, meanings, or morphology.

The current production Quran core is still ayah-only and intentionally has no canonical word-level identities. Therefore this policy is **dormant for Quran word rescue** until a legally preserved, provenance-backed word/gloss or morphology source passes the Source Vault and alignment gates.

Synthetic IDs in unit tests are test fixtures only.

## Versioning and evaluation

Current policy version: `rare-word-rescue-v1`.

The quick-peek threshold and scheduler-deferral contract are replaceable policy behavior, not durable user-history semantics. Future tuning must use labelled/observed learning outcomes and must not rewrite preserved exposure/review events.

No retention improvement is claimed until an instrumented, privacy-preserving evaluation can measure it on real eligible semantic units.
