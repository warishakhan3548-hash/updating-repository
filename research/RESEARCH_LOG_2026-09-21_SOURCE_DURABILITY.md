# Research Log — Independent Source Durability — 2026-09-21

## Scope

This review asks whether a project-controlled GitHub Source Vault alone satisfies the product's long-term source-durability promise. It does not copy, mirror, promote, or alter any Quran, Hadith, morphology, gloss, font, audio, translation, or timing bytes.

## Verified facts

| Type | Claim | Primary source | Verified | Confidence | Product implication |
| --- | --- | --- | --- | --- | --- |
| fact | GitHub says some deleted repositories can be restored within 90 days; repository deletion can permanently remove important repository state and is not itself an archival guarantee. | https://docs.github.com/en/repositories/creating-and-managing-repositories/deleting-a-repository | 2026-09-21 | High | The primary GitHub repository is not sufficient evidence of an independent long-term backup. |
| fact | Software Heritage can archive source-code repositories and assigns content-derived persistent SWHIDs to archived objects. | https://docs.softwareheritage.org/ and https://docs.softwareheritage.org/devel/swh-model/persistent-identifiers.html | 2026-09-21 | High | Software Heritage is a strong future independent archival option for legally public repository content, but archival presence must be verified before it is claimed. |
| fact | LOCKSS preservation guidance emphasizes multiple independent copies and warns that a single administrative/control domain can remain a common point of failure. | https://www.lockss.org/about/preservation-principles | 2026-09-21 | High | A second copy should be operationally independent and checksum-verified, not merely another path in the same repository. |

## Repository finding

The project already preserved the exact Tanzil v1.1 Quran artifact, licence snapshot and provenance under project control and validates their SHA-256 values. docs/SOURCE_POLICY.md also says critical artifacts should have an independent backup where practical.

However, that backup requirement was not executable. No machine-readable record established whether the current production-approved source had actually been copied to an independent storage domain, and the pack release gate could not distinguish "backup planned" from "backup verified".

## Decision

Add a small checksum-bound backup-attestation policy behind the existing content-pack release gate.

- Candidate/reviewed packs may continue to build while backup work is pending.
- Every production-approved source must be represented in the backup inventory.
- A backup may be pending without pretending provider, location class, verification time or verification method.
- A verified backup must bind to the exact Source Vault SHA-256, identify an independent storage class/provider, record a timezone-aware verification time, and state SHA-256 verification.
- A cryptographically valid approved content pack must fail closed unless its source backup is verified.
- The backup attestation is not Evidence Plane content and does not alter source bytes.

## Current state

quran.tanzil.uthmani.v1.1 remains pending for independent backup. This is intentional: the repository has not verified an off-GitHub byte-for-byte copy in this run, so it must not claim one.

Possible future storage targets include an independently administered cloud/archive copy, offline media, or an institutional archive. Software Heritage may be useful for public repository preservation, but a SWHID/archive lookup must be recorded only after successful archival and exact-object verification.

## Non-goals

- no invented backup URL or provider;
- no secret/private storage locator committed to the public repository;
- no assumption that a fork is administratively independent;
- no weakening of signature, source-vault, licence, or semantic-fidelity gates;
- no change to Android reader behavior.
