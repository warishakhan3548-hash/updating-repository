# Research Record — HadeethEnc Archival Rights — 2026-09-21

Purpose: decide whether HadeethEnc Arabic may enter the project's immutable public Source Vault before any Hadith artifact is downloaded or mirrored.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | HadeethEnc's official site exposes Arabic downloads in Excel and PDF formats. | https://hadeethenc.com/en | 2026-09-21 | High | Availability alone does not authorize permanent archival redistribution. |
| fact | HadeethEnc permits republication only under listed conditions including no modification, source attribution, version identification, preservation of transcript information, and updating the translation according to newer HadeethEnc versions. | https://hadeethenc.com/en | 2026-09-21 | High | Current-version republication and indefinite retention of superseded public snapshots are distinct rights questions. |
| existing project observation | The Source Vault registry records Arabic version `1.7.0-observed-2026-09-20` from the previous official-version audit. | source-vault/registry.json | 2026-09-21 | High for repository state; freshness requires release-time recheck | Do not treat the observed version as permanently current. |
| inference | The inspected public terms do not clearly establish permission to keep superseded HadeethEnc snapshots publicly mirrored indefinitely after a newer version appears. | official terms + project reproducibility requirement | 2026-09-21 | High | Keep HadeethEnc `awaiting-licence` and metadata-only until archival retention is explicitly cleared. |
| inference | Edition, collection, numbering, and grade provenance remain separate from copyright permission. | Evidence Plane architecture | 2026-09-21 | High | Legal clearance alone would not make the dataset production-authoritative. |

## Decision

Do **not** download, capture, or mirror HadeethEnc Arabic source bytes into the public Source Vault at this stage.

The registry therefore records HadeethEnc as:

- `awaiting-licence`;
- historical snapshot retention `unresolved`;
- latest-upstream review required before any future approved release;
- no Source Vault artifact, licence snapshot, provenance file, or checksum.

## Promotion path

Only after historical archival retention is explicitly documented as allowed:

1. move the source to a capture-authorized state;
2. verify the then-current official version;
3. acquire the exact official artifact and exact applicable terms;
4. preserve immutable bytes, provenance, sizes, and SHA-256 values;
5. independently verify edition/collection/numbering and grade/source semantics;
6. build a candidate canonical Hadith model and search benchmark;
7. perform the separate release-time latest-version review before an approved pack ships.

No production Hadith importer or search pack should depend on HadeethEnc before those gates pass.
