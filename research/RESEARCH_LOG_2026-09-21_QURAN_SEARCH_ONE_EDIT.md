# Research Record — Conservative Quran typo fallback — 2026-09-21

This experiment changes no Quran evidence bytes and introduces no external dataset. It starts from the current production-shaped reader search order: strict literal retrieval first, then the constrained orthographic/South-Asian spelling lane, then abstention.

## Problem

The labelled golden set still contains remembered-wording typo cases that the current runtime deliberately does not claim to support. A generic fuzzy matcher would be easy to add but risks returning sacred text on weak evidence.

## Hypothesis

A much narrower fallback can recover common multi-word one-character errors without making single-word guesses:

- run only after existing search lanes return no rows;
- require at least two query tokens;
- compare only contiguous same-width token windows;
- permit at most one edit across the entire query;
- label any future promoted result approximate;
- retain explicit abstention when no candidate clears the rule.

## Evaluation boundary

`tools/quran_search_one_edit_experiment.py` is host-side evaluation only. It must pass the versioned `quran-search-golden-v1` gate, including zero labelled no-answer false positives. Host latency is diagnostic and must not be presented as low-end Android performance.

No runtime promotion is implied by a passing experiment.
