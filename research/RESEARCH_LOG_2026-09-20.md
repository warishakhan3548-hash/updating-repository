# Research Log — 2026-09-20

Facts were checked against primary/official sources where available. Marketing claims are treated as product descriptions, not scientific proof. Architectural inference and experimental hypotheses are labelled separately.

| Type | Claim | Primary/official source | Confidence | Product implication |
|---|---|---|---:|---|
| fact | Tanzil Quran text lists release v1.1 (2021-02-12); its text terms permit verbatim copy/distribution with attribution/source link and prohibit changes. The selected Uthmani v1.1 artifact is now preserved in this project's Source Vault and promoted only through checksum/licence/provenance gates. | https://tanzil.net/download/ and https://tanzil.net/docs/Text_License | high | Approved Quran evidence foundation for the pinned configuration; never mutate its source/display bytes. |
| fact | The exact preserved Tanzil v1.1 artifact embeds a `Copyright (C) 2007-2026 Tanzil Project` notice, while the separately archived official Text License page displays `Copyright (C) 2007-2021 Tanzil Project`. The substantive verbatim/no-change/attribution terms align. | preserved Source Vault artifact plus https://tanzil.net/docs/Text_License | high | Preserve both records independently; do not rewrite one source to cosmetically match the other. |
| fact | Quranic Arabic Corpus download identifies morphology v0.4 and states GNU licence plus explicit verbatim/no-change and attribution conditions, while its official FAQ also describes the data as non-commercial research material. | https://corpus.quran.com/download/ and https://corpus.quran.com/faq.jsp | high | Keep QAC out of production until the licensing ambiguity is resolved or explicit permission is obtained. |
| fact | Quran Foundation developer terms updated 2026-09-14 restrict redistribution and generally storage beyond one week except documented sync content/explicit permission. | https://api-docs.quran.foundation/legal/developer-terms/ | high | Optional online integration only; not the critical permanent mirror. |
| fact | QuranEnc exposes versioned downloadable translations and permits re-publication subject to no-modification, source/publisher attribution, version and transcript conditions. | https://quranenc.com/en/home | high | Evaluate and preserve each exact translation/version independently. |
| fact | QUL says resources are intended to be downloaded/packaged, while also identifying external resource origins. | https://qul.tarteel.ai/resources | high | Verify each resource's provenance/licence individually; no blanket approval. |
| fact | QUL word-root/lemma resources are downloadable as local SQLite data, but QUL's FAQ tells commercial users to verify dataset-specific licence terms and its credits trace morphology to the Quranic Arabic Corpus plus later community work. | https://qul.tarteel.ai/resources/word-root and https://qul.tarteel.ai/resources/word-lemma and https://qul.tarteel.ai/faq and https://qul.tarteel.ai/credits | high | QUL is useful for discovery/alignment research but is not a licence shortcut around upstream morphology rights. |
| fact | HadeethEnc permits re-publication under no-modification, attribution, versioning and update conditions. | https://hadeethenc.com/en | high | Hadith candidate; collection/edition/numbering provenance still needs production review. |
| fact | Sunnah.com exposes an API and says an offline dump is not yet available. | https://sunnah.com/developers | high | Research/comparison candidate, not a durable offline foundation today. |
| fact | SQLite FTS5 includes unicode61/trigram tokenizers and BM25 ranking. | https://sqlite.org/fts5.html | high | Strong boring baseline for measured multi-lane local retrieval. |
| fact | Unicode UAX #15 defines canonical normalization. | https://www.unicode.org/reports/tr15/ | high | Normalize only derived search lanes; original Arabic remains immutable display evidence. |
| fact | Current FSRS documentation still centers the D/S/R model and FSRS-6, while the ecosystem already contains newer-version implementations/benchmark references. | https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm and https://github.com/open-spaced-repetition/awesome-fsrs | medium-high | Preserve raw review events and keep FSRS behind an adapter; never make one scheduler version part of the permanent user-data schema. |
| fact | Android recommends at least 48dp touch targets; WCAG 2.2 AA specifies 24x24 CSS px minimum with exceptions. | https://developer.android.com/guide/topics/ui/accessibility/views/apps-views and https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html | high | Use 48dp Android controls and expanded semantic hit regions for inline words. |
| fact | Android's offline-first architecture guidance keeps a local data source as the canonical source of truth for higher layers. | https://developer.android.com/topic/architecture/data-layer/offline-first | high | Reader UI should project the local verified content pack; network access stays off the critical read path. |
| fact | TUF publishes version/hash/signature/rollback-oriented update specifications. | https://theupdateframework.io/spec/ | high | Use its threat-model principles for content pack activation. |
| fact | GitHub states that pinning an Action to a full-length commit SHA is the only way to consume it as an immutable release. | https://docs.github.com/en/actions/reference/security/secure-use | high | Pin every remote Action/reusable workflow used by trusted evidence builds and reject movable refs in CI. |
| fact | Events caused by a repository `GITHUB_TOKEN` normally do not create another workflow run, including a workflow pushing a commit that another workflow listens for via `push`. | https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow | high | A pack-publishing workflow must validate the exact generated commit itself instead of relying on a second push-triggered foundation workflow. |
| fact | SPDX maintains machine-readable licence identifiers and canonical licence texts. | https://spdx.org/licenses/ | high | Prefer SPDX IDs when source terms match exactly; preserve custom terms when they do not. |
| fact | Quran.com added Study Mode and a related-Hadith tab in 2026, showing that users value contextual depth without abandoning the reading flow. | https://quran.com/product-updates | high | Keep our first tap lighter than a full study screen; when Hadith is shown, preserve edition-aware citations and explicit evidence boundaries. |
| fact | Quran.com exposes focused study/word-detail flows in addition to reading. | https://quran.com/en/product-updates/new-study-mode-on-quran-com | high | In-context depth is valuable; our first tap should stay lighter and reading-anchored. |
| fact | Tarteel emphasizes recitation follow-along, voice search, mistake detection and active recall; its support material also acknowledges that mistake detection can flag false positives. | https://tarteel.ai/ and https://support.tarteel.ai/ | high | Machine detections need confidence plus confirm/reject history; they cannot become unquestionable learning truth. |
| fact | Readlang uses click-to-translate reading plus saved contextual words/review; LingQ similarly combines contextual reading with tracked vocabulary/SRS. | https://readlang.com/features and https://www.lingq.com/en/learn-arabic-online/ | high | Supports reader-driven low-friction learning rather than a separate drill-first product. |
| fact | Quran Progress describes frequency-first Quran vocabulary plus spaced repetition. | https://www.quranprogress.com/en/ | medium | Useful comparison; independently reproduce corpus coverage before accepting numerical coverage claims. |
| inference | The best default comprehension assist is an anchored micro-gloss rather than navigation to a separate study screen. | synthesis of reader products + product north star | medium | Prototype and user-test before declaring final UX. |
| hypothesis | Natural re-exposure in the user's reading path can sometimes substitute for forced rare-word review. | cognitive/product hypothesis | medium | Evaluate against retention and interruption metrics. |

## First-principles synthesis

The main opportunity is not another feature dashboard. It is an invisible comprehension layer that learns how much explanation a person still needs and lets natural Quran encounters substitute for unnecessary drills.

Hadith research needs a different trust posture: multi-lane fuzzy retrieval with explicit abstention, edition-aware citations and attributed grade assertions. AI query expansion belongs outside the Evidence Plane.

## Open research gates

- exact QAC v0.4 bytes and field-level importer verification;
- per-resource QUL licences;
- authoritative redistributable Hadith datasets with edition-level numbering provenance;
- full HadeethEnc edition/collection mapping;
- exact QuranEnc translation/version selection where translations are used;
- fonts, audio and word/ayah timing sources with explicit redistribution rights.

## Saturation conclusion

The research now converges on four durable choices: immutable source/display data, contextual reader-first assistance, local event-preserving learning, and deterministic multi-lane retrieval with explicit uncertainty. Further research should answer concrete implementation/evaluation questions rather than accumulate features.

## Late-run trust and source update

| type | claim | source | confidence | product implication |
| --- | --- | --- | --- | --- |
| fact | Quran Foundation Developer Terms were updated 2026-09-14 and restrict redistribution/storage of API content outside specified cases; the service may also change or discontinue. | https://api-docs.quran.foundation/legal/developer-terms/ | high | Keep Quran Foundation useful only as an optional integration/research source; it is not the durable mirrored Evidence Plane foundation without separate permission. |
| fact | HadeethEnc's official site permits republication subject to no-modification, attribution, version-display and update conditions. The Arabic download endpoint was rate-limited during this run, so no exact production artifact/version was captured. | https://hadeethenc.com/en and https://hadeethenc.com/ar | high | Keep HadeethEnc as a research candidate until exact bytes, version, collection/edition mapping and numbering provenance are preserved and reviewed. |
| fact | SQLite documents `mode=ro` for read-only URI opens and `immutable=1` for files that must not change underneath the connection. | https://sqlite.org/uri.html | high | ReaderCore's combined `mode=ro&immutable=1` remains appropriate for immutable local content packs. |
| fact | TUF separates trusted keys/signatures from hash checking and defines metadata roles/versioning/expiry to resist rollback and freeze attacks. | https://theupdateframework.io/docs/metadata/ and https://theupdateframework.io/docs/security/ | high | A content pack must never become `approved` merely because signature-shaped strings exist; cryptographic verification against trusted keys is a separate release gate. |
| finding | The repository's previous pack gate checked only that `algorithm`, `key_id`, and `value` were non-empty for an `approved` pack; it did not verify the signature. | repository audit | high | Fail closed on every `approved` manifest until a real trusted-key verifier, canonical signed payload and rotation policy are implemented. |


## Semantic-fidelity update

| type | claim | source | confidence | product implication |
| --- | --- | --- | --- | --- |
| fact | SQLite stores file-level structural/version metadata such as the file change counter and the SQLite version that most recently modified the database. A runtime SQLite SHA-256 identifies exact file bytes but does not by itself prove semantic fidelity to an external preserved source. | https://sqlite.org/fileformat.html | high | Keep byte-integrity checking, but independently compare schema and Quran evidence rows/search lanes back to the pinned Source Vault before promotion. |

## Release-signing research update

| type | claim | source | confidence | product implication |
| --- | --- | --- | --- | --- |
| fact | TUF specification 1.0.36 (last modified 2026-08-05) models trusted root keys, threshold roles, deterministic/canonicalizable signed metadata, unique key IDs and rollback resistance. | https://theupdateframework.io/specification/latest/ | high | Adopt the narrow trust properties now—project-controlled root, threshold signatures and deterministic payload—without importing a full remote-update framework before it is needed. |
| fact | PyCA Cryptography 50.0.1 was released 2026-08-25; its official Ed25519 API verifies signatures directly from a public key and raises on invalid signatures. | https://pypi.org/project/cryptography/ and https://cryptography.io/en/latest/hazmat/primitives/asymmetric/ed25519/ | high | Use it as a replaceable CI/release verifier behind a project-owned signing format rather than making the library itself part of the data model. |
| fact | RFC 8785 requires duplicate-free JSON object names, preserves Unicode string data as supplied, constrains interoperable numbers, and sorts object property names by UTF-16 code units. It notes that ASCII-only property names avoid cross-encoding ordering differences. | https://www.rfc-editor.org/rfc/rfc8785.html | high | Keep signature format v1 deliberately narrower than full JCS: reject duplicates, restrict field names to ASCII, forbid floats, bound integers to the exact cross-runtime range, and preserve Unicode string values unchanged. |
| finding | The Android vertical slice initially used signature-shaped manifest fields as release readiness, then correctly moved to a temporary fail-closed block while trusted-key verification was absent. | repository audit through main b6a814f1836ffac0e8f7d1c87383e31fe63b3fcf | high | Replace the temporary block only by delegating Android release builds to the authoritative cryptographic pack gate; do not introduce a second trust rule. |
| inference | Generating a release private key inside CI/GitHub merely to unblock the current candidate would make key custody fragile and could create unrecoverable trust history. | threat-model review | high | Keep the trust root in bootstrap-required state until offline key generation and independent backup are deliberately established; do not manufacture an approval. |


## Release-ordering and Android verifier update

| type | claim | source | confidence | product implication |
| --- | --- | --- | --- | --- |
| fact | Android's `java.security.Signature` API lists Ed25519 support at API 33+, while SHA256withECDSA is available at API 11+. | https://developer.android.com/reference/java/security/Signature | high | Current Python Ed25519 verification is valid for build-time approval, but a future on-device updater for this minSdk-24 app must not assume platform Ed25519 exists on every supported device. |
| fact | TUF explicitly treats rollback as presenting an older version than a client has already seen, and its signed metadata uses version/freshness information so clients can reject obsolete state. | https://theupdateframework.io/docs/security/ and https://theupdateframework.io/docs/metadata/ | high | Keep rollback ordering authenticated, but implement persisted client state before enabling automatic downloaded-pack activation. |
| inference | A signed monotonic integer is a safer internal rollback-ordering primitive than parsing content-version strings because ordering semantics stay explicit and independent of naming conventions. | update threat-model synthesis | high | Require positive `release_sequence` on every approved manifest and sign it with the rest of the manifest. |


## Signature-domain refinement

| type | claim | source | confidence | product implication |
| --- | --- | --- | --- | --- |
| fact | RFC 8032 discusses cryptographic contexts as a way to separate signature uses between protocols and recommends a constant protocol-defined context where that mode is used; pure Ed25519 itself has no context input. | https://www.rfc-editor.org/rfc/rfc8032.html | high | Keep widely supported pure Ed25519, but prepend a fixed project-owned byte domain to the manifest message before signing/verifying so release signatures cannot be interpreted as raw signatures over an unrelated protocol payload. |
| decision | No production release key or approved signed pack exists yet, so defining the v1 application-domain prefix now does not invalidate any production trust history. | repository audit | high | Freeze the prefix before the offline key-bootstrap/signing ceremony and cover it with regression tests. |


## Release-key lifecycle hardening

| type | claim | source | confidence | product implication |
| --- | --- | --- | --- | --- |
| fact | TUF root metadata binds roles to trusted keys and thresholds, and TUF treats rollback as a distinct update-system threat. | https://theupdateframework.io/docs/metadata/ and https://theupdateframework.io/docs/security/ | high | Keep signed release ordering and explicitly bound retired-key authorization to historical release sequences. |
| finding | The write-capable Quran pack publisher installed `requirements-ci.txt` before a retry loop that can reset to a newer `main`. | repository audit | high | Install the verifier dependency after each reset so the exact tree being validated determines its verification dependency. |
| inference | Keeping a rotated key trusted forever for all future release numbers weakens compromise containment even when release ordering is signed. | trust-model analysis | high | Give active/retired/revoked keys explicit release-sequence windows; retired keys retain only historical authorization and revoked keys authorize nothing. |
