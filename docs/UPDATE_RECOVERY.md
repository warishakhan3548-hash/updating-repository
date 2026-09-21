# Content Update Recovery

This policy defines failure behavior before any automatic network updater is enabled.

## Core rule

A failed update must not make the locally verified Quran unavailable.

Release expiry controls whether signed metadata may authorize a **new activation**. It does not revoke an already verified local content pack and it does not make historical signatures unverifiable.

## Fail-closed recovery matrix

| Failure | Required behavior |
| --- | --- |
| Candidate signature or trust role is invalid | Discard the staged candidate; keep the current verified pack. |
| Candidate release metadata is expired | Refuse new activation, keep the current verified pack, and treat the update channel as stale. |
| Candidate is not valid yet | Refuse new activation; do not weaken time checks to make it pass. |
| Candidate release sequence is lower than the highest accepted sequence | Reject as rollback; never downgrade automatically. |
| Same release sequence names different bytes | Reject as a release-sequence collision. |
| Downloaded size/hash/SQLite integrity is wrong | Delete/quarantine the staged bytes; never point the reader at them. |
| Activation is interrupted | Preserve the previous verified pack and activation state; switching must remain atomic. |
| Trust keys are lost/compromised | Recover through separately reviewed trust-root/app-release procedures; do not add an unsigned bypass. |

## Clock failure

A future network updater must treat the device clock as security-sensitive input. If the clock is clearly unusable, freshness cannot be established. The safe behavior is to retain the current verified pack and report that update freshness could not be checked.

The project must not silently extend expiry, rewrite signed timestamps, or substitute server response time unless that time source is itself authenticated by the update protocol.

## Explicit downgrade recovery

Normal update logic has no downgrade escape hatch. If a severe incident ever requires installing bytes below the stored release sequence, that is a distinct recovery ceremony and must be represented by a separately reviewed app/trust policy change. It must not be remotely triggerable by ordinary pack metadata.

## Availability boundary

The Evidence Plane is durable local content. Update freshness protects acquisition of *new* content; it is not a lease on the user's ability to read already verified Quran offline.
