# Evidence Export and Verify-Back

## Purpose

External AI is never an Evidence Plane database.

The evidence-export boundary lets the application give another AI a small, explicit, source-traceable set of locally verified records, then verify the references that come back. It does **not** verify the external model's reasoning or conclusion.

## Version 1

`tools/evidence_bundle.py` is the single implementation owner for `aaris-evidence-bundle-v1`.

Version 1 deliberately supports only Quran ayahs from a provenance-bound `quran-core` pack. It introduces no new evidence dataset, network dependency, AI provider, search engine, or parallel Quran database.

Before reading records it delegates to the existing authoritative content-pack gate. Production use requires an `approved` pack. The repository's unsigned candidate may be exercised only through the explicit `--allow-candidate-for-development` flag.

An export contains only records explicitly selected by canonical citation ID.

## Outputs

One export directory contains:

- `evidence.json` — deterministic machine-readable evidence;
- `evidence.txt` — human/AI-readable UTF-8 evidence;
- `checksums.sha256` — SHA-256 values for both exported files.

The JSON binds the export to the local content pack and preserved source through pack/source hashes, licence/provenance hashes, canonical identity when present, canonical citation IDs, original Arabic, per-record text hashes, and source-assertion IDs. It also carries the validated source attribution, source/licence links, and the exact pack-local attribution notice so the export itself preserves redistribution obligations instead of depending on metadata left behind inside the app.

Search-normalized Quran text is never exported as display evidence.

The deterministic JSON serializer reuses the project's strict signed-metadata rules: duplicate object names, non-standard numeric values, invalid Unicode scalar values, floating-point values, unsafe integers, and non-ASCII object keys are not accepted by that serializer. The bundle hash is SHA-256 over those deterministic UTF-8 JSON bytes.

## Citation identity

For Quran v1, the citation identifier is the existing app-owned Quran coordinate:

`qa:SSS:AAA`

Example:

`qa:002:255`

Future Hadith evidence must use the edition-aware canonical Hadith identity already defined by the Evidence Plane. It must not be bolted onto this Quran implementation before an eligible Hadith pack exists.

## Verify-back

Verify-back performs deterministic checks in this order:

1. require the exact expected evidence-bundle SHA-256 produced at export time;
2. validate the local content pack through the existing pack gate;
3. require the bundle's complete pack descriptor and exact attribution notice to match that local pack;
4. reload every exported citation from the read-only local SQLite pack;
5. require every exported record to exactly match the locally reconstructed source-faithful record;
6. require every Quran citation returned by the external answer to belong to the exported evidence scope.

A valid Quran citation that exists elsewhere in the local database is still rejected if it was not part of this export. This prevents a model from silently escaping the evidence scope while citing a technically real reference. Verify-back also requires the exact export SHA-256, so changing the research question, instructions, attribution wrapper, or evidence bytes produces a different bundle and cannot be silently accepted.

Successful verification says:

**References verified**

It never says:

**Conclusion verified**

## External-AI instruction boundary

The plain-text export tells the external model to:

- answer only from supplied evidence;
- cite supplied canonical IDs exactly;
- state when evidence is insufficient;
- not silently use web search or model memory as Quran/Hadith evidence;
- not invent grades, editions, numbering, translations, or source claims.

This instruction is defense-in-depth. Local verify-back remains the software trust boundary.

## Example

Development export against the current candidate pack:

```bash
python tools/evidence_bundle.py \
  export \
  --citation qa:001:001 \
  --citation qa:002:255 \
  --question "Answer only from these supplied ayahs." \
  --out /tmp/aaris-evidence \
  --allow-candidate-for-development
```

Verify a returned UTF-8 answer:

```bash
python tools/evidence_bundle.py \
  verify \
  --bundle /tmp/aaris-evidence/evidence.json \
  --answer /tmp/external-answer.txt \
  --expected-bundle-sha256 <sha256> \
  --allow-candidate-for-development
```

The development override exists only because the current Quran pack is intentionally `candidate` / unsigned. Production export remains fail-closed until normal pack approval succeeds.

## Why PDF is not version 1

PDF is a presentation derivative, not the machine trust anchor. Shipping a PDF renderer now would add a dependency before Arabic shaping, RTL behavior, font provenance, copy/paste fidelity, and accessibility of the generated document have been evaluated.

When PDF is added, it should render from the same already-verified evidence bundle. It must not create another evidence data path.

## Privacy

The export contains only the explicitly selected evidence and the optional research question supplied for that export.

It does not include reading history, learning history, scheduler state, notes, bookmarks, device identity, or unrelated search history.

No network request is made by the evidence-bundle implementation.
