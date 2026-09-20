# QuranEnc Arabic Difficult-Word Source Audit — 2026-09-21

## Current decision

QuranEnc **Arabic Language - Meanings of Words** (`arabic_seraj`) remains a promising contextual-gloss candidate, but it is **awaiting-licence** and is not a production or Source Vault dependency.

The current public tree intentionally contains **no QuranEnc source payload snapshot**. The registry therefore keeps `vault_artifact`, `licence_snapshot`, `provenance`, hashes and byte size unset until archival redistribution is explicitly cleared.

## Verified official facts

Verified on 2026-09-21 from QuranEnc's official pages:

- the resource is exposed as `Arabic Language - Meanings of Words`;
- the documented API supports translation-list metadata and Surah/ayah retrieval;
- republication is allowed only under source-specific conditions;
- those conditions include no modification, publisher/source attribution, version disclosure, keeping transcript information, reporting notes, updating according to the latest source version, and avoiding inappropriate advertising around Quran translation content.

Primary pages:

- https://quranenc.com/en/browse/arabic_seraj
- https://quranenc.com/en/home/api

## Licence / durability boundary

The unresolved issue is not whether QuranEnc permits any republication. The unresolved issue is whether its requirement to keep republished content updated to the latest source version is compatible with this project's stronger durability rule: retain immutable historical public snapshots so old builds remain reproducible years later.

Until authoritative clarification or another legally durable basis establishes that historical retention is permitted:

1. keep the registry status `awaiting-licence`;
2. do not mirror QuranEnc payload bytes into the public Source Vault;
3. do not build a runtime gloss pack from QuranEnc;
4. do not use QuranEnc as a morphology, TokenID, LexemeID, SenseID, root or grammar authority;
5. keep the acquisition tool fail-closed before any network request;
6. after licence clearance, move to `awaiting-artifact` in a separately reviewed change before acquisition.

## Historical capture correction

Commit `95e8fc41fae70c4687e41ac887df7ab0c2c2eb48` temporarily added a review-only QuranEnc snapshot before the archival-rights question had been cleared.

That contradicted the later fail-closed policy now encoded by the registry and capture tool. The live tree therefore removes those payload files and keeps only this metadata/research record.

This correction is deliberately **not** a Git history rewrite. Historical Git objects may still contain the earlier snapshot. Purging published history would require an explicit repository-history rewrite and force-push decision, which this project does not perform implicitly.

## Product architecture consequence

If the licence gate is later cleared, QuranEnc should be treated only as an attributed **verse-scoped contextual gloss assertion**.

Safe reader flow:

`QuranCoordinate + tap surface → deterministic unambiguous phrase match → contextual gloss → continue reading`

Rules:

- Tanzil remains the authoritative Quran display source;
- the gloss remains a separate Learning Plane assertion;
- no fuzzy match may silently become Evidence Plane identity;
- ambiguous or missing alignment must abstain;
- morphology may later link through an explicit provenance-backed overlay without rewriting either source.

This preserves the north-star interaction while keeping evidence, morphology and learning identities separate.
