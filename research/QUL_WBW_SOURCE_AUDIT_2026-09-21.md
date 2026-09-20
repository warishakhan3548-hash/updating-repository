# QUL Word-by-Word Gloss Source Audit — 2026-09-21

Purpose: evaluate whether Quranic Universal Library (QUL) word-by-word translations can legally and technically unlock the north-star interaction `Read → get stuck → tap → understand → keep reading` without weakening the Source Vault rules.

## Verified facts

| Claim | Primary source | Verified | Confidence | Licence / trust implication | Product implication |
|---|---|---:|---|---|---|
| QUL resource **92** is **English Word by Word Translation**, labels itself word-by-word, and exposes JSON and SQLite downloads. | https://qul.tarteel.ai/resources/translation/92 | 2026-09-21 | High | A concrete downloadable candidate exists, but a download control is not itself a redistribution licence. | Technically attractive for instant English contextual word help. |
| QUL resource **44** is **Hindi wbw translation**, labels itself word-by-word, and exposes JSON and SQLite downloads. | https://qul.tarteel.ai/resources/translation/44 | 2026-09-21 | High | Same legal gate as resource 92. | High-value Hindi contextual word-help candidate. |
| QUL's official FAQ says commercial users must check repository terms **and dataset-specific licensing details** before production use. | https://qul.tarteel.ai/docs/faq ; https://qul.tarteel.ai/faq | 2026-09-21 | High | The QUL platform/repository licence cannot be treated as a blanket licence for every hosted dataset. | Every QUL resource stays independently gated. |
| QUL's credits page says the majority of QUL resources were created or curated by the community and specifically credits **QuranWBW.com** for word-by-word translations in multiple languages. | https://qul.tarteel.ai/credits | 2026-09-21 | High | QUL is an aggregator/curator for these data; source lineage matters. | Provenance must include upstream content owners, not merely QUL. |
| QuranWBW's published site states that data used there belongs to the respective owners/authors and that copying it is not allowed. | https://legacy.quranwbw.com/ | 2026-09-21 | High for the published notice; Medium for how it maps to each exact QUL resource | Do not infer downstream archival/redistribution rights from QUL availability. QUL may have permissions that are not documented on the inspected resource page, but this project has not verified a grant to us. | No Source Vault capture until a resource-specific legal basis is documented. |

## Decision

Register:

- `quran-gloss.qul.english-wbw.resource-92`
- `quran-gloss.qul.hindi-wbw.resource-44`

as **`awaiting-licence`** metadata-only candidates.

Do **not** download, mirror, checksum, import, or ship their dataset bytes yet.

This is deliberately stricter than “the files are downloadable”. Availability is a technical fact; permission to make an immutable project-controlled public archive and redistribute it in product builds is a separate legal fact.

## Why this is still valuable

These two sources are among the strongest UX candidates inspected so far because they are already word-scoped and map naturally to the user's desired interaction:

`tap a word → show a tiny contextual meaning → continue reading`

They could reduce the dependency on a full morphology corpus for the first useful tap experience. But they should be treated as **contextual gloss assertions**, not as Quran text authority and not as morphology.

If rights later clear:

1. preserve exact authorized QUL artifact bytes plus the resource page, applicable licence/permission, upstream source attribution and checksums;
2. verify the resource's exact coordinate/word-position coverage against the project's Quran Evidence Plane;
3. keep Tanzil `original_text` unchanged and authoritative for display;
4. map QUL word positions to app-owned canonical token/occurrence IDs only after deterministic alignment proves the mapping;
5. keep English and Hindi glosses in independently versioned optional learning packs;
6. abstain on ambiguous or mismatched coordinates rather than binding a meaning to the wrong Quran word;
7. do not derive roots, lemmas, grammar, or Hadith evidence from these gloss files.

## Clearance requirements

Before either candidate can move to `awaiting-artifact`, obtain a resource-specific basis that resolves, at minimum:

- redistribution of exact source bytes;
- commercial use, if the distributed application may be commercial;
- whether modification/normalization is allowed and what attribution is required;
- permission to retain and redistribute immutable historical snapshots for reproducible builds;
- the provenance relationship between QUL, QuranWBW.com and the underlying translation owners/authors;
- any version/update obligation that must be enforced at release time.

If those rights cannot be verified, these sources remain non-critical research candidates and the reader continues to show no word-tap meaning rather than using unlicensed or unverifiable content.
