# Aaris Pharmacy — Offline Decision Engine Map

## Goal

Make the default Aaris engine useful without a cloud API or a local LLM. The engine must stay deterministic, offline-first, fast, reviewable, and conservative around stock-changing actions.

This is a domain-specific expert engine, not a general-purpose language model. It should feel intelligent because evidence is narrowed, fused, ranked, cross-checked, and allowed to abstain instead of guessing.

## Dependency tree

```text
Camera / Photo / Video / Typed command
│
├─ Vision intake
│  ├─ ML Kit OCR + line geometry
│  ├─ Barcode / GS1 evidence
│  └─ frame quality + sequence + timestamp
│
├─ MedicineIntakeService
│  ├─ durable SQLite capture queue
│  ├─ pharmacist-reviewed local identity snapshot
│  ├─ optional canonical catalogue candidates
│  └─ background isolate compute
│
├─ MedicineUnderstandingEngine (Tier 0 evidence parser)
│  ├─ OCR cleanup
│  ├─ near-duplicate frame fusion
│  ├─ medicine boundary grouping
│  ├─ composition / salt / strength parsing
│  ├─ batch / MFG / EXP / form / manufacturer parsing
│  ├─ local barcode consensus
│  └─ field confidence + conflict detection
│
├─ MedicineProductResolverV2 (Tier 1 coherent resolver)
│  ├─ exact barcode candidate path
│  ├─ rare lexical candidate retrieval
│  ├─ bounded delete-neighbour recovery
│  ├─ prefix + trigram cascade
│  ├─ product-level hypothesis scoring
│  ├─ hard contradiction vetoes
│  ├─ adaptive score/margin lock thresholds
│  └─ ambiguity -> human review
│
├─ MedicineSearch (hot local retrieval)
│  ├─ exact canonical barcode
│  ├─ exact medicine terms
│  ├─ IDF-style rare-term candidate votes
│  ├─ bounded identity-only delete-neighbour typo/OCR recovery
│  ├─ selective prefix / trigram / bigram recovery
│  ├─ lazy cached scope checks only for retrieved candidates
│  ├─ bounded final candidate set
│  └─ weighted field reranking + strength conflict penalty
│
├─ AppBrain (command decision firewall)
│  ├─ negation / future / compound-write safety block
│  ├─ deterministic intent routing
│  ├─ exact-context rules
│  ├─ winner / runner-up ambiguity margin
│  └─ reviewed mutation paths
│
└─ UI / Controller
   ├─ reviewable scan draft
   ├─ exact record open/search
   ├─ FEFO / lifecycle projections
   └─ explicit confirmation before destructive stock changes
```

## Visual/state map

```text
User scans pack
  -> capture is durably queued
  -> OCR/barcode evidence extracted on-device
  -> deterministic parser creates field candidates
  -> coherent product resolver cross-checks identity
  -> confidence + contradiction gates decide:
       GREEN: inherit verified identity
       YELLOW: keep draft for review
       CONFLICT: preserve observed evidence, never overwrite it
  -> review UI
  -> pharmacist confirms
  -> inventory write

User types/speaks command
  -> AppBrain safety firewall
  -> deterministic intent
  -> MedicineSearch candidate cascade:
       exact ID/barcode
       -> rare exact terms
       -> bounded delete-neighbour typo/OCR recovery
       -> prefix/trigram/bigram recovery
       -> weighted rerank + contradiction penalties
  -> high-confidence separated winner OR review/abstain
  -> existing action preview / confirmation
  -> inventory write only through authoritative controller path
```

## Surgical intersection point

The V2 product resolver already used a bounded search-engine-style cascade and adaptive confidence. MedicineSearch still had two hot-path gaps:

1. Every non-empty query built an `allowed` set by scanning the entire indexed inventory before looking at bounded fuzzy postings. This made keystroke/search cost contain an unnecessary O(N) scope pass even when only a small number of candidates were relevant.
2. General inventory search relied on exact/prefix/trigram/bigram nomination before the expensive weighted ranker. Mixed OCR confusions such as `D0LO` could be recovered by later similarity logic only if a weaker gram channel happened to nominate the record first.

The V3 upgrade fixes both at the original search engine layer:

- scope eligibility is memoized lazily only for IDs reached through bounded postings;
- an OCR-folded delete-neighbour channel nominates likely typo candidates before edit-distance ranking;
- delete-neighbour memory is deliberately capped to the first 18 identity-heavy alphabetic terms per record and terms up to 24 characters;
- the new channel never grants authority. Existing weighted ranking, strength contradictions, Brain winner/runner-up margin checks, exact-context rules, confirmation gates, and controller writes remain authoritative.

Empty-query list views still intentionally scan/sort the selected inventory projection because the user requested a complete list rather than a search.

## Performance model

For a non-empty query, work should scale with selective posting lists and the bounded candidate cap rather than with every inventory row:

```text
normalize query
  -> exact identifier lookup
  -> selective indexed postings
  -> lazy scope check(candidate IDs only)
  -> top <= 240 candidates
  -> expensive weighted similarity
  -> sorted results
```

The delete-neighbour index is not a second full fuzzy dictionary. It is a small identity-first accelerator. Long OCR payloads, receipts, notes and arbitrary text stay out of that high-memory channel.

## Engine rules

1. Exact verified identifiers outrank fuzzy evidence.
2. Rare evidence carries more retrieval weight than ubiquitous words.
3. Expensive similarity runs only on a bounded candidate set.
4. Independent evidence may corroborate; repeated noisy evidence must not dominate.
5. Conflicting strength/barcode/identity evidence lowers confidence or forces review.
6. No cloud call is required for the default engine.
7. Optional Local AI may refine a deterministic draft but can never be required for intake/search correctness.
8. Destructive operations keep explicit confirmation and never inherit fuzzy target authority.
9. Unknown is a valid decision. The engine must abstain rather than fabricate certainty.
10. Performance is achieved by early narrowing, bounded work, cached candidate-only scope checks, and isolate/background processing—not by skipping safety checks.
11. Memory-heavy typo structures must remain identity-focused and explicitly bounded.
12. A retrieval channel may nominate candidates; only calibrated downstream evidence is allowed to authorize an automatic target.

## Public engineering benchmarks used for the design direction

- SQLite FTS5: inverted full-text retrieval, IDF/BM25 ranking and bounded ranked results.
- Apache Lucene FuzzyQuery: bounded edit-distance fuzzy expansion and top-term scoring rather than unconstrained dictionary-wide similarity.
- Google ML Kit: on-device OCR/barcode processing for real-time and offline mobile flows.
- GS1 Healthcare: exact structured identifiers such as GTIN, batch/lot and expiry take precedence over fuzzy text when present.

These are architecture benchmarks, not claims that Aaris embeds those engines or that any proprietary pharmacy product uses the same implementation.
