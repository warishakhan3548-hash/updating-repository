# QAMAR Morphology Source Audit — 2026-09-21

## Scope

Evaluate QAMAR as a current morphology candidate for the trusted word-level layer. This review does not approve or mirror any QAMAR dataset bytes.

## Verified facts

| Claim | Primary source | Confidence | Licence / durability implication | Product implication |
| --- | --- | --- | --- | --- |
| QAMAR was published at AbjadNLP 2026 and describes a manually verified morphological layer for every Quranic word, including MSA equivalent, stem, lemma, root and POS. | https://aclanthology.org/2026.abjadnlp-1.38/ | High | Technically relevant to canonical word/morphology alignment. | Strong research candidate for morphology evaluation. |
| ACL Anthology exposes optional supplementary material for the paper. | https://aclanthology.org/2026.abjadnlp-1.38/ | High | Download availability is not itself a redistribution or commercial-use licence. | Do not capture merely because bytes are downloadable. |
| The paper's Ethics Statement says the corpus will be open-source for the academic community and publicly available for research and educational purposes. | https://aclanthology.org/2026.abjadnlp-1.38.pdf, p. 311 | High | This wording does not establish a production-compatible grant for commercial redistribution, modification, or immutable historical public mirroring. | Keep metadata-only as `awaiting-licence`. |
| The same statement says study data came from publicly available sources or was generated during the research process, but it does not provide a component-by-component rights manifest. | https://aclanthology.org/2026.abjadnlp-1.38.pdf, p. 311 | High | Public availability is not proof that every embedded/derived component can be relicensed or mirrored by this project. | Record `component_rights_status: unresolved`. |

## Decision

Register `morphology.qamar.2026` as metadata-only `awaiting-licence`.

No QAMAR ZIP, table, corpus row, or derivative runtime data is mirrored or consumed by the application in this run.

Promotion requires, at minimum:

1. an explicit dataset licence or written permission covering the exact artifact;
2. commercial-use permission for the intended distribution model;
3. redistribution and modification scope;
4. permission to retain immutable historical snapshots for reproducible builds;
5. a reviewed component-rights chain for source Quran text and any reused annotations;
6. exact artifact version, checksum and coordinate/word alignment against the project's Tanzil Evidence Plane.

## Architectural consequence

This review exposed a broader Source Vault weakness: third-party/component rights were described in prose for MASAQ/EQTB/QUL but were not an executable gate. The repository now records `component_rights_status` and refuses capture, preservation, or production approval unless that status is `reviewed-clear` or `not-applicable`.

This keeps the trust model fail-closed without pretending that software can decide copyright ownership automatically.
