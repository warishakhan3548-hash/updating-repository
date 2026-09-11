# Aaris Pharmacy — Offline Decision Engine Map

## Goal

Make the default Aaris engine useful without a cloud API or a local LLM. The engine stays deterministic, offline-first, fast, reviewable, and conservative around stock-changing actions.

This is a pharmacy-domain expert engine, not a general-purpose language model. It feels intelligent by narrowing evidence early, combining independent clues, vetoing contradictions, and abstaining instead of guessing.

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
├─ MedicineProductResolverV2 (Tier 1 coherent product resolver)
│  ├─ exact barcode candidate path
│  ├─ rare lexical candidate retrieval
│  ├─ bounded delete-neighbour recovery
│  ├─ prefix + trigram cascade
│  ├─ product-level hypothesis scoring
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

## V4 surgical intersection point

V3 already fixed the expensive candidate-retrieval problems: it removed the non-empty-query O(N) scope scan and added bounded OCR delete-neighbour nomination. The next hot-path weakness was the final `rank()` stage.

Before V4, every retrieved candidate re-normalized and re-split the same medicine fields for every keystroke. Ranking also selected mostly the single best matching field. A query containing several independent clues such as brand + salt + strength + form therefore could not fully benefit from their agreement.

V4 changes the original `MedicineSearch` core rather than adding another wrapper:

1. normalized field projections and identity words are built once when the search index is built;
2. candidate retrieval stays bounded and unchanged in authority;
3. reranking can fuse several independent identity clues into one coherent product hypothesis;
4. strength remains the stronger product-variant contradiction gate;
5. dosage form adds a separate variant contradiction gate so a same-name/same-strength tablet cannot silently outrank a requested syrup;
6. long exact internal record IDs receive explicit exact-match authority, while short generic IDs do not;
7. fuzzy/lexical evidence still cannot bypass AppBrain ambiguity, preview, confirmation, or controller write rules.

## Performance model

For a non-empty query, cost scales with selective postings and the bounded candidate cap rather than the full inventory:

```text
index build / inventory revision
  -> normalize searchable fields once
  -> cache field words + identity words
  -> build exact / rarity / delete / prefix / n-gram postings

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
4. Independent clues may corroborate; repeated noisy clues must not dominate.
5. Product identity must be coherent across fields; one convenient field cannot erase a trusted contradiction.
6. Conflicting strength is a strong safety signal; conflicting dosage form is a product-variant safety signal.
7. No cloud call is required for the default engine.
8. Optional Local AI may refine a deterministic draft but is never required for intake/search correctness.
9. Destructive operations keep explicit confirmation and never inherit fuzzy target authority.
10. UNKNOWN / review is a valid outcome. The engine must abstain rather than fabricate certainty.
11. Performance comes from early narrowing, precomputation, bounded work and isolate/background processing—not skipped checks.
12. Retrieval channels nominate candidates; calibrated downstream evidence is what may raise confidence.

## Public engineering benchmarks used for the design direction

- SQLite FTS5: inverted retrieval, BM25/IDF-style ranking, prefix/phrase search and bounded ranked results.
- Apache Lucene FuzzyQuery: bounded edit-distance expansion and top-term scoring instead of unbounded dictionary-wide fuzzy comparison.
- Google ML Kit: on-device text/barcode extraction suitable for real-time offline mobile paths when models are bundled.
- Google LiteRT: optional future small specialist models can run on-device and use available CPU/GPU/NPU acceleration; they are not required for the deterministic baseline.
- GS1 Healthcare: structured identifiers such as GTIN, batch/lot, manufacturing date and expiry are higher-authority evidence than fuzzy OCR text.

These are public architecture benchmarks. They are not claims that Aaris embeds proprietary Big-Tech code or that any named pharmacy company uses this exact implementation.
