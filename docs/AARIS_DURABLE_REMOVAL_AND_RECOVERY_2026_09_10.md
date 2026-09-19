# Aaris durable removal & recovery upgrade — 10 September 2026

## Why this exists

Aaris already used soft archive and a 200-event activity journal. The journal is
excellent for Undo, but it is intentionally bounded; after enough later changes,
a removal reason could disappear from history even though the removed medicine
row still existed. That is weak provenance for a pharmacy inventory system.

## New authoritative lifecycle

- Every new single, protected bulk, AI-reviewed, or backup-reconciliation removal
  goes through one domain transition and writes `archiveReason` plus `archivedAt`
  on the same authoritative `Medicine` row.
- Those fields are system-owned audit metadata. They are stored/backed up but are
  not in `Medicine.editable`, so AI cannot rewrite them as medicine facts.
- Restore goes through the paired domain transition and clears removal metadata.
  If a restored row is still SOLD or expired, those independent deterministic
  states remain intact; restore does not manufacture on-hand stock.
- Old backups/rows with `archived=true` and no provenance remain valid for
  backward compatibility. Partial or stale removal metadata is rejected.
- Removed Stock sorts known removal times newest first and shows reason/date.

## AI recovery safety

The local inventory tool already had explicit `archived`/`get` reads. It may now
propose `restore` only for an exact archived ID it actually retrieved. The app
still owns the schema, revision, replay ID and mutation. Remove, whole-stock SOLD,
and Restore are deliberately not pre-selected in an AI multi-change review; the
pharmacist must select them and then press Apply.

This adds no second database, cloud sync, treatment engine, or direct AI SQL path.
All changes still converge on the existing atomic inventory mutation pipeline and
remain undoable.
