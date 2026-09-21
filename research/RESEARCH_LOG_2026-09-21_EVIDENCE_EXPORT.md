# Research Record — Evidence Export Boundary — 2026-09-21

Purpose: turn the already-documented Ask-with-other-AI trust boundary into an executable local evidence export without adding a new evidence dataset, cloud dependency, or duplicate retrieval system.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Android's platform `Ed25519` `Signature` algorithm is available from API level 33, while this app currently supports API 24+. | Android `java.security.Signature` / cryptography documentation | 2026-09-21 | High | Do not pretend an Android-platform-only Ed25519 verifier covers every supported device. A future on-device verifier for API 24–32 needs a deliberately selected/audited compatibility strategy or a raised minimum SDK. |
| fact | TUF separates metadata roles and requires signed metadata to expire; Timestamp metadata is intentionally short-lived so clients can detect stale/freeze conditions. | The Update Framework specification/documentation | 2026-09-21 | High | Freshness for a future remote update channel should be authenticated update metadata, not an ad-hoc mutable expiry field bolted onto immutable content bytes. |
| fact | Deterministic/canonical JSON representation is a prerequisite when independent implementations need stable cryptographic representations of the same JSON data. | RFC 8785, JSON Canonicalization Scheme | 2026-09-21 | High | Reuse the repository's existing strict deterministic JSON boundary for machine evidence instead of inventing a second serializer. |
| fact | Current `main` already documents evidence export and verify-back conceptually but has no implementation owner for either. | repository audit at `e1cfc8cc39659219b6eb6d1caf07551404ca06fb` | 2026-09-21 | High | Implement one deterministic owner rather than adding another architecture-only document or parallel evidence database. |
| inference | A local bundle hash plus exact record revalidation can prove which local evidence was exported and whether it changed; it cannot prove that an AI's reasoning is correct. | Evidence Plane model + local deterministic verification | 2026-09-21 | High | Product wording must say **References verified**, never **Conclusion verified**. |
| hypothesis | Deterministic JSON plus UTF-8 plain text is sufficient for the first trustworthy external-AI workflow; PDF can follow as a renderer after Arabic/RTL/accessibility tests. | product architecture | 2026-09-21 | Medium | Avoid an early PDF dependency and keep the trust anchor format simple. |

## First-principles comparison

Three implementation directions were considered.

### 1. Build automatic remote content updates now

Rejected for this run. The existing repository correctly blocks the feature. On-device cryptographic support across the current Android API floor, authenticated freshness, staging/recovery, and trust-root rotation are still unresolved as one coherent protocol.

### 2. Acquire another word-level or Hadith dataset

Rejected for this run. Current candidates remain blocked by rights-chain, historical-retention, commercial-use, exact-artifact, or edition/alignment gates. Downloading bytes anyway would violate the Source Vault policy rather than advance it.

### 3. Implement the missing evidence-export / verify-back owner

Selected.

It can be built completely over already-preserved Quran evidence and existing pack validation. It requires no external data, no licence inference, no network permission, and no provider SDK.

## Design decisions

- Format ID: `aaris-evidence-bundle-v1`.
- V1 evidence type: Quran ayahs only.
- Production source requirement: existing pack gate + `approved` review status.
- Current candidate access: explicit development-only override.
- Selection: explicit canonical citation IDs, preserving requested order.
- Machine form: deterministic UTF-8 JSON.
- Human/AI form: UTF-8 text derived from the same bundle.
- Integrity: SHA-256 over canonical bundle bytes plus a checksum file for export artifacts; verify-back requires the exact bundle SHA-256 produced at export time.
- Display evidence: source-faithful `original_arabic` only; normalized search strings are excluded.
- Verify-back: reconstruct exported records from the validated local pack and reject returned citations outside that exact export scope.
- Result language: `References verified`; conclusion verification is explicitly false.
- No external AI call is performed by this module.
- No user learning/search history is exported.

## Deferred deliberately

- PDF rendering, until Arabic shaping, RTL, font provenance, copy/paste, and accessibility are tested.
- Android sharing UI, until the host trust boundary and file contract are stable.
- Hadith evidence records, until a production-eligible edition-aware Hadith source exists.
- Automatic remote content updates, until freshness, recovery, API-24-compatible signature verification, and key-rotation design are complete.

## Source Vault impact

None.

This run adds no external dataset bytes, changes no production source status, and creates no new production dependency. The existing Tanzil Source Vault snapshot remains the only production-approved evidence source.
