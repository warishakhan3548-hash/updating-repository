# Aaris Tiny Brain v1

This folder is the first trained-model bundle for Aaris Pharmacy.

It deliberately does **not** replace the existing deterministic pharmacy safety
boundary. The models assist routing and OCR understanding only. Existing
`AppBrain` mutation guards, exact-ID resolution, reviewed AI envelopes,
revision checks and SQLite transactions remain authoritative.

## Models

- `intent_hybrid_int8.json` — tiny Hindi/Hinglish/English medicine-command
  router. 14 intents, 192 hashed features, per-class int8 weights.
- `ocr_role_hybrid_int8.json` — tiny OCR line-role classifier. 11 roles, 256
  hashed character features, per-class int8 weights.
- `reference_router.py` — reference inference path for the quantized artifacts.

Both deployed artifacts are hybrid: high-risk/domain boundary phrases are handled
by ordered deterministic anchors first, then the trained classifier handles the
remaining language variation. This is intentional: a tiny classifier must never
be allowed to invent direct delete/SOLD/quantity authority.

## Training notes

Training was performed outside GitHub on CPU using supervised medicine/Hinglish
examples, hard-example mining and held-out challenge sets. A larger neural OCR
teacher was also trained with backpropagation and reached 43/44 on its synthetic
holdout; the compact deployment model was then kept small and paired with the
existing deterministic parser.

Recorded evaluation in `manifest.json` is limited to synthetic/domain test
sets. It is not a claim of pharmacy, clinical, or worldwide medicine accuracy.

## Intended chain

```
User / OCR
  -> existing deterministic safety firewall
  -> tiny intent / OCR helper
  -> existing medicine resolver + validators
  -> reviewed action envelope
  -> PharmacyController
  -> atomic SQLite commit
```

The next engineering step is to wire this bundle behind an explicit backend or
local experimental route and collect real pharmacist-reviewed corrections before
any broader accuracy claim.
