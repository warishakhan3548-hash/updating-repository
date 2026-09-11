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
│  ├─ OCR edit-neighbour recovery
│  ├─ prefix + trigram cascade
│  ├─ product-level hypothesis scoring
│  ├─ hard contradiction vetoes
│  ├─ adaptive score/margin lock thresholds
│  └─ ambiguity -> human review
│
├─ MedicineSearch (hot local retrieval)
│  ├─ exact canonical barcode
│  ├─ exact medicine terms
│  ├─ rare-term / IDF candidate votes
│  ├─ selective trigram / bigram recovery
│  ├─ bounded candidate set
│  └─ weighted field reranking + strength conflict penalty
│
├─ AppBrain (command decision firewall)
│  ├─ negation / future / compound-write safety block
│  ├─ deterministic intent routing
│  ├─ exact-context rules
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
  -> MedicineSearch candidate retrieval
  -> exact/high-confidence target or review/abstain
  -> existing action preview / confirmation
  -> inventory write only through authoritative controller path
```

## Surgical intersection point

The current scan resolver already uses a bounded search-engine-style cascade and adaptive confidence. The remaining hot-path mismatch was `MedicineSearch`: its candidate generation used flat exact + bigram votes, which can over-expand common-token postings as inventory grows.

The upgrade therefore belongs inside `MedicineSearch` candidate generation, before the existing weighted `rank()` stage. The final field weights, exact barcode path, scope filters, archive isolation, strength mismatch penalty, FEFO ordering, and mutation review semantics remain authoritative.

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
10. Performance is achieved by early narrowing, bounded work, and isolate/background processing—not by skipping safety checks.
