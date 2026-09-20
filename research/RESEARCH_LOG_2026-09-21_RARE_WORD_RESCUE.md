# Research Record — Rare-Word Rescue and Natural Exposure — 2026-09-21

Purpose: define a minimal deterministic policy for deciding when a personally difficult semantic unit should interrupt Quran reading with a standalone review, without manufacturing word identity or treating passive reading as successful recall.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | FSRS-6 represents memory with Difficulty, Stability and Retrievability, and uses Again/Hard/Good/Easy review grades. | https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm | 2026-09-21 | High | Consume scheduler retrievability when supplied, but keep equations/parameters outside durable event identity. |
| fact | Vocabulary learned through reading can benefit from retrieval and from encountering target words in varied contexts; the effect depends on successful retrieval opportunities rather than mere exposure count. | https://pubmed.ncbi.nlm.nih.gov/30648796/ | 2026-09-21 | High | Reading encounters can sometimes be useful review opportunities, but should not automatically be treated as successful recall. |
| fact | Experimental work on variable retrieval practice examines how spacing and contextual variation affect later recall/generalization across multiple experiments rather than supporting a simple "more variation is always better" rule. | https://pubmed.ncbi.nlm.nih.gov/39453748/ | 2026-09-21 | High | Keep future context rotation measured and pedagogical rather than random. |
| fact | In contextual vocabulary learning, retrieval and meaning inference can both improve retention, while retrieval success and contextual informativeness matter. | https://pubmed.ncbi.nlm.nih.gov/35436027/ | 2026-09-21 | High | Do not replace a difficult review with a natural encounter when the memory state suggests retrieval is unlikely. |
| inference | A product-level natural-exposure rule should substitute the *location of the opportunity*, not fabricate evidence that recall succeeded. | Sources above + repository event-ledger boundary | 2026-09-21 | High | `NATURAL_EXPOSURE` does not create a review-success event. |
| fact | FSRS uses configurable desired retention; retrievability is a memory-model output rather than a universal product-level substitution threshold. | https://github.com/open-spaced-repetition/py-fsrs and https://docs.ankiweb.net/deck-options | 2026-09-21 | High | Keep due-review deferral inside the scheduler adapter instead of imposing a global 0.60 floor in the rescue policy. |
| hypothesis | Two quick-meaning opens since the last success are enough to count as weak personal struggle evidence for enrollment. | Product hypothesis | 2026-09-21 | Experimental | Version the threshold and tune only from measured outcomes later. |

## Decision

Implement one pure local policy over already-existing Learning Plane signals.

- Enrollment is path-dependent and personal; global corpus rarity alone does nothing.
- Passive visibility is never recall success.
- Unknown scheduler retrievability remains unknown.
- An already-due scheduler review fails closed to explicit review unless the scheduler adapter explicitly authorizes deferral to a predicted natural encounter.
- Optional retrievability can inform ranking and diagnostics without becoming a universal substitution threshold.
- The policy accepts canonical semantic IDs but creates none.

## Non-goals

- no new Quran/Hadith/morphology/gloss source;
- no Source Vault promotion;
- no FSRS parameter optimizer;
- no Android review UI;
- no hidden background scheduler;
- no context graph fabricated from whitespace tokenization;
- no retention-quality claim.

This leaves the visible reader unchanged while making the future Learning Plane behavior deterministic and testable.
