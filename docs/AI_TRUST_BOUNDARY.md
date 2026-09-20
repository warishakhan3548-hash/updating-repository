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
