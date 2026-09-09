# Aaris Default Local AI

Aaris keeps one privacy-first, one-click default model role without embedding
hundreds of megabytes of weights in the APK.

## Priority

1. A user-selected local model, when one is active.
2. The downloaded **Aaris Default Local AI**.
3. The existing offline medicine-understanding engine: ML Kit OCR + barcode +
   layout + pharmacy field/entity rules + reviewed local identity memory +
   deterministic MFG/EXP validation.

The third path is always available. Declining, cancelling, losing connectivity,
running out of storage/RAM, or failing model activation must never disable the
scanner.

## Default download

The default policy currently resolves the public
`tensorblock/Qwen2.5-0.5B-Instruct-GGUF` repository and prefers a balanced
single-file Q4_K_M weight in the requested roughly 300–400 MB class. The
catalogue response is resolved to an immutable revision and SHA-256 before the
existing downloader accepts it. GGUF metadata inspection, RAM admission and the
existing structured pharmacy setup probes still run before activation.

The repository name is a discovery policy, not execution authority. If the
preferred artifact disappears, becomes gated, falls outside the size band, is
malformed, is unsupported by the pinned runtime or fails the setup probes, Aaris
keeps the deterministic scanner instead of guessing or silently using cloud AI.

## Consent and persistence

The model is never silently downloaded. Medicine capture offers **Download &
activate** with the approximate network size first. Once activation succeeds, a
small local manifest remembers that model as the Aaris default. The normal local
model manifest continues to own the actual weights and active runtime.

If the owner later activates another compatible local model, that explicit model
wins. If no local model is active, Aaris can restore the remembered default on
the next capture/AI request. If no default exists, the deterministic scanner is
used immediately.

## What this intentionally does not claim

- The default is a general instruction-tuned local LLM, not a fabricated
  pharmacy-specialist training artifact.
- It does not replace deterministic EXP/MFG chronology or evidence validation.
- It does not turn a model's confidence into stock-write authority.
- A dedicated trained Pharmacy NER model can be added later, but no untrained or
  fake NER weights are bundled merely to satisfy an architecture label.
