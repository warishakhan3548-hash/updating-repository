# Licence Matrix — 2026-09-21

| Source | Intended use | Current status | Key implication |
|---|---|---|---|
| Tanzil Quran Text v1.1 | Quran Evidence Plane source | **production-approved** | Exact Uthmani `txt-2` snapshot is preserved in Source Vault. Official terms allow verbatim copying/distribution with attribution/source link and prohibit changing the Quran text. |
| QuranEnc Arabic Meanings of Words (As-Siraj) v1.0.0 | contextual difficult-word gloss candidate | **awaiting-licence** | Official catalogue identifies v1.0.0 and permits republication under source-specific conditions, but the terms also require updating to newer source versions and do not clearly establish indefinite public redistribution of superseded snapshots. No source bytes may enter the public Source Vault until archival retention is clarified. If that gate clears, the separate signed source-release review still enforces latest-version eligibility for each approved pack. It is a gloss source, not a morphology or Quran-text authority. |
| Quranic Arabic Corpus v0.4 | morphology candidate | **awaiting-licence** | Official download presents GNU GPL/verbatim-copy terms, while the official FAQ also says research/non-commercial use. This conflict must be resolved before production redistribution/commercial use; no artifact promotion. |
| QuranMorph (SinaLab/Birzeit, 2025) | morphology candidate | **awaiting-artifact** | Official SinaLab catalogue labels the Quran morphology dataset CC BY 4.0. The current publisher download form limits free-edition access to recognized institutional/company affiliations and professional email; no exact bytes/version have been acquired or mirrored. The paper's 6,235-verse count must also be reconciled against this project's 6,236-ayah Tanzil coordinates before promotion. |
| Quran Foundation APIs | optional online integration | **rejected as critical vault source** | Current developer terms make it unsuitable as the permanent mirrored evidence foundation. |
| QUL / Tarteel resources | per-resource discovery | **awaiting-licence** | Official QUL morphology pages expose downloadable word-location keyed lemma/root/stem resources, but QUL's FAQ says commercial use requires checking dataset-specific licensing and the inspected morphology pages do not expose a dataset licence. Repository MIT licensing must not be treated as blanket data licensing. |
| QUL English WBW resource 92 / Hindi WBW resource 44 | contextual word-gloss candidates | **awaiting-licence** | Both official resource pages expose JSON/SQLite downloads, but QUL requires dataset-specific licence review and credits QuranWBW.com for word-by-word translations. QuranWBW's published notice says its data belongs to respective owners/authors and copying is not allowed. This does not establish that QUL lacks hosting permission; it means this project has no verified downstream archival/redistribution grant. No bytes are mirrored. |
| QAMAR (AbjadNLP 2026) | morphology candidate | **awaiting-licence** | ACL publishes a manually verified word-level morphology resource and supplementary material, but the paper only states academic/research/educational availability; this review did not verify an explicit dataset licence covering commercial redistribution, modification, immutable archival mirroring, or a complete component-rights chain. No QAMAR bytes are mirrored. |
| HadeethEnc Arabic | Hadith source candidate | **awaiting-licence** | Official version check reports Arabic v1.7.0. Current republication terms require downstream copies to track newer versions, but do not clearly establish indefinite public redistribution of superseded snapshots. Commercial-use permission is also not independently verified. No HadeethEnc bytes may enter the public Source Vault until archival retention is clarified; edition/collection/numbering provenance remains a separate later gate. |
| Sunnah.com API | comparison/research candidate | **research-only** | Useful for research/API comparison, but not a durable mirrored offline foundation while an authoritative offline dump is unavailable. |

## Tanzil preserved snapshot

- source ID: `quran.tanzil.uthmani.v1.1`
- version: `1.1`
- project-controlled artifact: `source-vault/quran/tanzil/1.1/uthmani-marks-sajdah-rub/quran-uthmani.txt`
- artifact SHA-256: `4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f`
- licence snapshot SHA-256: `1ef7fbb0454f64ed4cceb838337808969711155f36147d1b357fc083336f4c68`
- provenance SHA-256: `733a938c4f54f082bf7f4e0b1d9bff7ce21afedceeba199294e872a428a57505`
- redistribution allowed: yes, under the archived source-specific terms;
- modification allowed: no;
- attribution required: yes.

The registry and executable Source Vault gate are authoritative for promotion state; this document is a human-readable summary.

## Commercial-use release gate

Commercial permission is machine-readable and independent from redistribution permission. Production-approved sources must set `commercial_use_allowed: true`; unknown or false values fail both the Source Vault gate and the runtime pack gate.

The Quranic Arabic Corpus v0.4 is explicitly `commercial_use_allowed: false` because its official FAQ currently limits downloaded research data to non-commercial research use, while the separate official download page also presents GPL/verbatim-copy terms. The source therefore remains blocked pending clarification rather than treating redistribution language as commercial authorization.

Tanzil Quran Text v1.1 is `commercial_use_allowed: true` under its archived CC BY 3.0/source-specific terms, which allow verbatim use in websites or applications without a non-commercial restriction. QuranMorph is also recorded `true` under its declared CC BY 4.0 licence, but remains `awaiting-artifact` and cannot ship until exact authorized bytes and coordinate alignment pass the normal gates. Candidates whose commercial status has not been independently verified remain `null`, not guessed.

## Component-rights release gate

The Source Vault now treats dataset-level licence permission and embedded/derived component rights as separate machine-readable review dimensions. `awaiting-artifact`, preserved snapshots, and `production-approved` sources fail closed unless `component_rights_status` is `reviewed-clear` or `not-applicable`.

MASAQ v5, EQTB v1, QUL-derived candidates, QAC, QuranEnc/HadeethEnc candidates, and QAMAR remain explicitly unresolved where component or downstream rights are not sufficiently established. Tanzil and the current QuranMorph capture candidate are recorded as reviewed clear for this gate; all other existing licence, provenance, artifact, and coordinate-alignment gates still apply.
