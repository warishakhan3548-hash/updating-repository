# QuranEnc Arabic Difficult-Word Capture Audit — 2026-09-21

## Decision

QuranEnc **Arabic Language - Meanings of Words** (`arabic_seraj`) was captured in commit `95e8fc41fae70c4687e41ac887df7ab0c2c2eb48` as a **review-only candidate** while the currently issued v1.0.0 was redistributable under QuranEnc's published conditions. A subsequent durability review found that those terms do not clearly establish indefinite public retention after a newer version appears. The candidate is therefore **not production-approved**, is excluded from registry artifact fields, and is removed from the active Source Vault tree pending clarification.

The capture uses QuranEnc's documented Surah translation API rather than the unreliable bulk CSV route. Exact response bytes for Surahs 1–114 were preserved without modification, together with the official resource index, resource page, terms snapshot, provenance and checksums.

## Verified upstream facts

- official resource: `Arabic Language - Meanings of Words`;
- source attribution: *As-Siraj fi Bayan Gharib Al-Quran*;
- upstream version observed at capture: `V1.0.0`;
- API contract: `/api/v1/translation/sura/{translation_key}/{sura_number}`;
- captured translation key: `arabic_seraj`;
- captured coordinate set: 114 Surahs / 6,236 ayahs;
- display/source bytes are preserved exactly; no morphology, TokenID, LexemeID, SenseID, root or grammar identity is inferred.

Primary pages:
- https://quranenc.com/en/home
- https://quranenc.com/en/browse/arabic_seraj
- https://quranenc.com/en/home/api
- https://quranenc.com/en/home/about/terms-and-conditions

## Preserved candidate

Historical capture path in commit `95e8fc41fae70c4687e41ac887df7ab0c2c2eb48`:

`source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0/`

The current tree intentionally does not retain these bytes while historical-retention permission is unresolved. The hashes below remain the audit reference for that capture.

Important integrity values from the captured commit:

- aggregate API snapshot-manifest SHA-256: `8cbc4f5f41298e438f7862fff1eba309ffdab254ca240257bd5b652631f2396c`;
- preserved terms HTML SHA-256: `24dd28bc25f21e59a2ec87137faeb0d969c1401232d99d2177cabf887c48341c`;
- preserved official index HTML SHA-256: `fe260d3728b6e0dd544c29695f96ac3fa0deda500dd28d9d704bfa47c1606322`;
- preserved browse/source page SHA-256: `64284343dbff99dc3bfd2f343a156d2b6745b7bd99b7f0d5677ba168c4762299`.

The aggregate manifest cryptographically binds the 114 response records through their individual SHA-256 values and coordinate metadata. `sha256.txt` additionally binds every captured upstream file, the snapshot manifest and provenance.

## Licence / durability boundary

The preserved QuranEnc terms permit downloading and republication subject to conditions including no modification, clear publisher/source attribution, version disclosure, retaining transcript information, reporting notes to the source, updating to the latest issued source version, and avoiding inappropriate advertising around Quran translation content.

The update obligation creates a material unresolved question for this project's **permanent immutable historical Source Vault** policy: the project intends to retain old verified snapshots indefinitely for reproducibility, while QuranEnc requires republished content to track the latest issued version.

Therefore:

1. keep the registry entry `awaiting-licence` with no artifact/provenance/hash promotion fields;
2. remove the review capture from the active Source Vault tree while historical retention remains unresolved;
3. do not build a production gloss pack from those bytes;
4. obtain explicit clarification/permission for permanent historical retention, or choose a source whose terms clearly permit it;
5. if permission is obtained, either restore the exact audited snapshot where legally permitted or reacquire the then-current official version through the gated capture path and compare it against the recorded hashes;
6. still perform the separate signed latest-version review before approving any future pack;
7. if permission is denied, keep QuranEnc outside the permanent-production path and use a legally durable alternative.

The historical Git commit remains part of the audit trail because this change does not rewrite repository history. A history purge would be a separate destructive operation requiring explicit authorization and a concrete legal/operational reason.

Capture evidence is not a licence conclusion.

## Product architecture consequence

If the licence gate is later cleared, this source should remain a **verse-scoped contextual gloss assertion**, not morphology.

Safe reader flow:

`QuranCoordinate + tap surface → deterministic unambiguous phrase match → source-faithful contextual gloss → continue reading`

Rules:

- Tanzil remains the authoritative Quran display source;
- QuranEnc text remains an attributed learning assertion;
- no fuzzy match may silently become Evidence Plane identity;
- ambiguous or missing phrase alignment must abstain;
- morphology can later link through an explicit overlay without rewriting this source.

This preserves the north-star interaction while keeping evidence, morphology and learning identities separate.
