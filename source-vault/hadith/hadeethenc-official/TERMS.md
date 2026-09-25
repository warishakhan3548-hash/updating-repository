# HadeethEnc source terms and provenance

Aaris stores the files in this directory as an immutable, repository-local source snapshot for
offline builds. The source publisher is HadeethEnc.com (Encyclopedia of Translated Prophetic
Hadiths).

Official source:
- https://hadeethenc.com/
- Download pages recorded in SOURCE.json
- Each workbook retains HadeethEnc's own transcript block, including language, last-update time,
  version, update-check URL and the instruction not to remove that information.

Reuse conditions recorded from the publisher at snapshot time:
1. Do not modify, add to, or delete from the source content.
2. Clearly attribute the publisher/source, HadeethEnc.com.
3. Preserve the translation version/source transcript and check source updates before repinning.
4. Do not place inappropriate advertising alongside the content.

Aaris policy:
- Source workbook bytes are never edited.
- SHA-256 values in SOURCE.json are release gates.
- The Android build consumes only this checked-in snapshot; it does not call HadeethEnc at runtime.
- Arabic is the canonical HadeethEnc record text. English, Hindi and Urdu are independent
  translation layers keyed only by the official HadeethEnc record id.
- A translation row is never attached to another record by fuzzy text similarity.
- Missing language rows stay missing and may fall back to another displayed language; Aaris does
  not generate or silently fill an official translation.
- The source explanation, benefits and takhrij fields remain archived in the original workbooks even
  when a current app screen uses only the hadith text/grade/reference.
