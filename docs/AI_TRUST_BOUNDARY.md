# AI Trust Boundary

AI is outside the Evidence Plane.

AI may understand research intent, generate multiple Arabic search variants, reason over an evidence export explicitly supplied to it, and return proposed citation IDs for local verification.

AI may not author or mutate Quran/Hadith source text, invent collection/edition/numbering/grade, silently write Evidence Plane records, replace deterministic local retrieval, or turn an unverified conclusion into "verified".

## Ask with other AI

```
question
→ external AI generates Arabic query variants
→ local deterministic search runs each variant
→ ranked verified local records
→ export PDF + text + JSON
→ external AI reasons only over export
→ answer returns with citation IDs
→ app verifies citation existence/source/quote locally
```

A successful verify-back message is **References verified**, not **Conclusion verified**.

## Executable evidence bundle v1

`tools/evidence_bundle.py` now implements the first executable export/verify-back boundary for Quran ayahs. It delegates to the existing authoritative content-pack gate, requires an `approved` pack in normal use, and permits the current unsigned candidate only behind an explicit development flag.

The export is deterministic JSON plus UTF-8 plain text and a checksum set. It carries canonical citation IDs, original source Arabic and the pack/source/provenance hashes needed to bind the evidence back to the local verified pack. Search-normalized Quran text is not exported as display evidence.

Verify-back reconstructs every exported record from the validated local pack and rejects a returned citation when it was not inside that exact evidence export, even if the citation exists elsewhere in the local Quran database. The module makes no network request and invokes no AI provider.

PDF rendering, Android sharing UI and Hadith evidence records remain separate later layers. A successful local check still means **References verified**, never **Conclusion verified**. See `docs/EVIDENCE_EXPORT.md`.
