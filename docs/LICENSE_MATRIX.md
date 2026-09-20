# Licence Matrix — 2026-09-21

| Source | Intended use | Current status | Key implication |
|---|---|---|---|
| Tanzil Quran Text v1.1 | Quran Evidence Plane source | **production-approved** | Exact Uthmani `txt-2` snapshot is preserved in Source Vault. Official terms allow verbatim copying/distribution with attribution/source link and prohibit changing the Quran text. |
| QuranEnc Arabic Meanings of Words (As-Siraj) v1.0.0 | contextual difficult-word gloss candidate | **awaiting-licence / quarantined review snapshot** | Official catalogue identifies v1.0.0 and permits republication under source-specific conditions, but the terms also require updating to newer source versions and do not clearly establish indefinite public redistribution of superseded snapshots. A snapshot captured before ADR-019 is retained only as quarantined review evidence and verified offline; registry artifact fields remain null and no build may consume it. No new capture or production promotion is allowed until archival retention is clarified. |
| Quranic Arabic Corpus v0.4 | morphology candidate | **awaiting-licence** | Official download presents GNU GPL/verbatim-copy terms, while the official FAQ also says research/non-commercial use. This conflict must be resolved before production redistribution/commercial use; no artifact promotion. |
| QuranMorph (SinaLab/Birzeit, 2025) | morphology candidate | **awaiting-artifact** | Official SinaLab catalogue labels the Quran morphology dataset CC BY 4.0. The current publisher download form limits free-edition access to recognized institutional/company affiliations and professional email; no exact bytes/version have been acquired or mirrored. The paper's 6,235-verse count must also be reconciled against this project's 6,236-ayah Tanzil coordinates before promotion. |
| Quran Foundation APIs | optional online integration | **rejected as critical vault source** | Current developer terms make it unsuitable as the permanent mirrored evidence foundation. |
| QUL / Tarteel resources | per-resource discovery | **awaiting-licence** | Official QUL morphology pages expose downloadable word-location keyed lemma/root/stem resources, but QUL's FAQ says commercial use requires checking dataset-specific licensing and the inspected morphology pages do not expose a dataset licence. Repository MIT licensing must not be treated as blanket data licensing. |
| HadeethEnc Arabic | Hadith research candidate | **research-candidate** | Official version check currently reports Arabic v1.7.0 and republication terms are promising, but the exact v1.7.0 artifact plus edition/collection/numbering provenance and preserved terms are still required before Evidence Plane promotion. |
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

### QuranEnc quarantined review snapshot

- path: `source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0/`
- version: `1.0.0`
- aggregate API manifest SHA-256: `8cbc4f5f41298e438f7862fff1eba309ffdab254ca240257bd5b652631f2396c`
- original capture provenance SHA-256: `a34107eb5edc90122bbdfcb5906639e69d19f5cf3a038e08e66709c510132b82`
- archived terms SHA-256: `24dd28bc25f21e59a2ec87137faeb0d969c1401232d99d2177cabf887c48341c`
- contents: official index/source/terms pages plus 114 exact Surah API responses covering 6,236 ayahs;
- legal state: unresolved for immutable historical public retention;
- production state: **not registered, not production-approved, not consumable by content builders**.

The registry and executable Source Vault gate are authoritative for promotion state; this document is a human-readable summary.
