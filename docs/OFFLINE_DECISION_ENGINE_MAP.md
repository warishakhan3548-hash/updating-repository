# Aaris Pharmacy — Offline Decision Engine Map

## Goal

Make the default Aaris engine useful without a cloud API or a local LLM. The engine stays deterministic, offline-first, fast, reviewable, and conservative around stock-changing actions.

This is a pharmacy-domain expert engine, not a general-purpose language model. It feels intelligent by narrowing evidence early, combining independent clues, weighting evidence by authority and capture quality, vetoing contradictions, and abstaining instead of guessing.

## Dependency tree

```text
Camera / Photo / Video / Typed or Voice Query
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
├─ MedicineUnderstandingEngine (Tier 0 parser)
│  ├─ OCR cleanup
│  ├─ near-duplicate frame fusion
│  ├─ medicine boundary grouping
│  ├─ composition / salt / strength parsing
│  ├─ batch / MFG / EXP / form / manufacturer parsing
│  ├─ local barcode consensus
│  └─ field confidence + conflict detection
│
├─ MedicineProductResolverV2 (Tier 1 coherent product resolver, V5 policy)
│  ├─ exact barcode candidate path
│  ├─ rare lexical candidate retrieval
│  ├─ bounded delete-neighbour recovery
│  ├─ prefix + trigram cascade
│  ├─ quality-aware independent-frame identity consensus
│  ├─ duplicate-frame authority suppression
│  ├─ product-level hypothesis scoring
│  ├─ decision-evidence authority mass
│  ├─ hard contradiction vetoes
│  ├─ adaptive score/margin lock thresholds
│  └─ ambiguity -> human review
│
├─ MedicineSearch V4 (hot local decision engine)
│  ├─ exact canonical barcode / long exact record ID
│  ├─ exact medicine terms + IDF-style rarity votes
│  ├─ bounded identity-only delete-neighbour OCR recovery
│  ├─ selective prefix / trigram / bigram candidate cascade
│  ├─ lazy candidate-only scope checks
│  ├─ bounded final candidate set (<= 240)
│  ├─ precomputed normalized field projections
│  ├─ weighted per-field reranking
│  ├─ multi-clue coherent identity evidence fusion
│  ├─ strength contradiction veto/penalty
│  └─ dosage-form variant contradiction penalty
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

## Visual / state map

```text
User scans a medicine pack
  -> capture is durably queued
  -> OCR / barcode evidence is extracted on-device
  -> deterministic parser creates observed field candidates
  -> coherent product resolver cross-checks identity
       -> quality-weights unique frame evidence
       -> collapses exact duplicate frame authority
       -> separates weak corroboration from decision-grade evidence
       -> requires enough authoritative evidence mass before auto-lock
  -> confidence + contradiction gates decide:
       GREEN: verified identity may prefill
       YELLOW: keep draft for review
       CONFLICT: preserve observed evidence; never overwrite it
  -> pharmacist review
  -> authoritative inventory write

User types / speaks / OCR-searches
  -> normalize once
  -> exact identifier path
  -> rare exact postings
  -> bounded OCR typo recovery
  -> prefix / trigram / bigram recovery
  -> lazy scope check only for nominated candidates
  -> top <= 240 candidate documents
  -> cached field-vector rerank
  -> coherent multi-clue evidence fusion
  -> strength + dosage-form contradiction gates
  -> high-confidence separated winner OR review / abstain
  -> existing preview / confirmation
  -> inventory write only through the authoritative controller path
```

## V5 surgical intersection point

V4 already made the search hot path bounded and moved repeated normalization out of per-keystroke ranking. The next material weakness was inside the original product resolver's final hypothesis decision.

Before V5, a candidate could achieve a very high normalized score from one strong fuzzy identity match plus a low-authority clue such as dosage form. The resolver still had ambiguity and contradiction gates, but its `channels >= 2` requirement did not distinguish *how authoritative* those two channels were. Repeated video/OCR frames also were not explicitly prevented from looking like extra identity support at this final decision layer.

V5 changes the original `MedicineProductResolverV2` core rather than adding a wrapper:

1. identity matching now forms a bounded consensus from the structured draft plus unique OCR frames;
2. frame identity evidence is quality-weighted using the existing bounded `MedicineFrameEvidence.quality` signal;
3. exact duplicate frame fingerprints are collapsed before corroboration, so repeated frames cannot manufacture confidence;
4. multi-frame agreement gets only a small bounded corroboration lift and never barcode-like authority;
5. the hypothesis tracks **decision evidence mass** separately from its normalized similarity score;
6. identity, salt, strength, verified barcode and very strong manufacturer agreement contribute decision authority; dosage form remains useful corroboration and contradiction evidence but cannot by itself manufacture the second authoritative proof;
7. ordinary auto-lock now requires both the existing score/channel/margin gates **and** at least `0.50` decision evidence mass;
8. exact verified barcode lock remains a separate high-authority path;
9. hard strength/form/name/GS1 contradictions still veto canonical inheritance;
10. candidate tie-breaking prefers higher decision authority after score, so equally similar products favor broader coherent evidence rather than incidental weak matches.

### Why `0.50` decision mass

The mass gate is intentionally interpretable rather than learned from opaque model weights. Examples under the current evidence weights:

```text
fuzzy identity (.36) + dosage form (weak corroboration)  -> .36  -> REVIEW
fuzzy identity (.36) + manufacturer (.05)               -> .41  -> REVIEW
identity (.36) + strength (.18)                          -> .54  -> eligible
identity (.36) + salt (.19)                              -> .55  -> eligible
identity (.36) + salt (.19) + strength (.18)             -> .73  -> strong
verified exact barcode                                   -> separate exact lock path
```

Eligibility is not the same as acceptance: score, product verification, runner-up separation, contradictions and downstream review/write guards still apply.

## Performance model

For a non-empty query or product resolution, cost scales with selective postings and bounded candidate/evidence caps rather than the full inventory:

```text
index build / inventory revision
  -> normalize searchable fields once
  -> cache field words + identity words
  -> build exact / rarity / delete / prefix / n-gram postings

scan resolution
  -> exact identifiers
  -> bounded candidate retrieval (<= 96 products)
  -> max 12 resolver frames
  -> max 16 text lines per frame for identity evidence
  -> duplicate-frame fingerprint collapse
  -> bounded alias comparison
  -> coherent score + authority mass + contradiction gates

keystroke / voice / OCR query
  -> normalize query
  -> exact identifier lookup
  -> selective indexed postings
  -> lazy scope check(candidate IDs only)
  -> top <= 240 candidates
  -> cached-field similarity + coherent evidence fusion
  -> contradiction gates
  -> sorted results
```

Expensive similarity remains bounded. OCR text and notes do not enter the high-memory delete-neighbour identity channel. Empty-query list views intentionally scan/sort the selected inventory projection because the user asked for a complete list, not a search.

## Engine rules

1. Exact verified identifiers outrank fuzzy evidence.
2. Rare evidence carries more retrieval weight than ubiquitous words.
3. Expensive similarity runs only on a bounded candidate set.
4. Independent clues may corroborate; repeated or duplicate noisy clues must not dominate.
5. Product identity must be coherent across fields; one convenient field cannot erase a trusted contradiction.
6. A high normalized score is not enough for automation; enough decision-grade evidence authority must also be present.
7. Dosage form is useful variant evidence but is not identity-grade proof by itself.
8. Conflicting strength is a strong safety signal; conflicting dosage form is a product-variant safety signal.
9. Capture quality may reduce noisy-frame influence but can never turn weak evidence into exact authority.
10. No cloud call is required for the default engine.
11. Optional Local AI may refine a deterministic draft but is never required for intake/search correctness.
12. Destructive operations keep explicit confirmation and never inherit fuzzy target authority.
13. UNKNOWN / review is a valid outcome. The engine must abstain rather than fabricate certainty.
14. Performance comes from early narrowing, precomputation, bounded work and isolate/background processing—not skipped checks.
15. Retrieval channels nominate candidates; calibrated downstream evidence is what may raise confidence.

## Public engineering benchmarks used for the design direction

- SQLite FTS5: inverted retrieval, BM25/IDF-style ranking, prefix search and trigram/substring-capable tokenization patterns.
- Apache Lucene FuzzyQuery: bounded edit-distance expansion and top-term scoring instead of unbounded dictionary-wide fuzzy comparison.
- Google ML Kit: on-device text/barcode extraction suitable for real-time offline mobile paths when required models are available locally.
- Apple Core ML: public example of hardware-aware on-device inference across CPU/GPU/Neural Engine while keeping data local; Aaris does not depend on Core ML on Android.
- Google LiteRT: optional future specialist models can use available mobile acceleration; they are not required for the deterministic baseline.
- GS1 Healthcare: structured identifiers such as GTIN, batch/lot, manufacturing date and expiry are higher-authority evidence than fuzzy OCR text.

These are public architecture benchmarks. They are not claims that Aaris embeds proprietary Big-Tech code or that any named pharmacy company uses this exact implementation.
