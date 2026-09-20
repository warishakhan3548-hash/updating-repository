# Review Context Rotation v1

The reader remains primary. Context rotation changes which verified example is used when a review opportunity already exists; it does not create extra review pressure.

## Boundary

`ReviewContextRotationPolicy` accepts:

- one existing app-owned semantic-unit ID;
- candidate Quran/Hadith context references;
- a verified semantic-unit ↔ context binding flag;
- familiarity and prior-use history derived from the Learning Plane;
- successful-review count.

It does not discover occurrences, create lexical identity, modify Quran/Hadith evidence, or decide whether a review is due. Those remain separate responsibilities.

## Deterministic progression

Policy version: `context-rotation-v1`.

Early phase:

1. prefer a familiar verified context;
2. prefer Quran over Hadith on otherwise comparable candidates;
3. use pedagogical rank, prior use, recency and stable reference ordering as deterministic tie-breaks.

Variation phase:

1. prefer the least-used verified context;
2. then the least-recently used;
3. then pedagogical rank;
4. prefer Quran on a tie;
5. finally use the stable context reference.

The default familiar phase lasts for the first two successful reviews. That threshold is an explicit experimental product parameter, not a literature-derived optimum.

## Hadith boundary

Hadith contexts are disabled by default. They become eligible only when the caller explicitly enables them and supplies an already-verified semantic binding to a trusted Hadith record. This policy never weakens edition/source identity or turns a parallel narration into a merged record.

## Learning history

No schema migration is required. Existing `review_event.context_ref` can preserve which context was used. Prior-use and recency projections may be rebuilt from append-only review history.

Passive visibility still is not recall. Selecting a context does not itself write a positive review outcome.

## Validation

JVM tests lock:

- rejection of unverified and wrong-semantic bindings;
- familiar verified Quran preference in the early phase;
- least-used/least-recent rotation later;
- Hadith opt-in;
- deterministic tie-breaking.

No retention benefit is claimed until real eligible semantic units and a labelled learning evaluation exist.


## Activation gate

The current production Quran core is still ayah-only. Word-level gloss/morphology candidates, including newly audited QUL word-by-word candidates, remain outside production until their own Source Vault licence, archival and alignment gates clear. Therefore this selector stays dormant in the visible reader and must not be fed guessed whitespace-derived word identities.
