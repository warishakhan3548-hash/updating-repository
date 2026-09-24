# Offline search, reading and recitation fixes — 23 September 2026

## Implemented

Quran and Hadith use one search screen, opened from either reader/library. All/Quran/Hadith
filters share the same input; explicit references select their corpus. `2:255` selects Quran,
`556` searches all local Hadith collections, and `Sahih Bukhari 556`/`सही बुखारी ५५६` filter
Bukhari before retrieval. `5 5 6` is accepted as individually spaced digits. Collection aliases
include English, Hindi, Arabic and Urdu; installed collection titles extend the aliases.
Explicit letter suffixes remain exact; a bare number also includes its letter variants, never a
longer number such as 5560. Missing references return no result, not a fuzzy substitute.

Arabic search normalizes vowel marks, tatweel, Arabic presentation forms, pasted bidi controls
and Unicode digits in search shadows only. Python index building and Java query normalization
have shared regression cases. Original display text, negation and Hindi vowel signs are retained.
Reference lookup uses dedicated number/reference indexes and bypasses prose ranking. Search
cancellation/generation checks prevent older queries from replacing newer results. Results remain
paged, attributed and selectable for the existing Quran/Hadith PDF exports.

Whole-ayah recitation now derives the provider's 1-based address from the canonical coordinate
and checks it against the 0-based local ordinal. The old cache was keyed by the requested verse
but could contain the previous verse's audio. `recitations-v2-coordinate` deliberately does not
reuse those files; selected recitation downloads need to be acquired again. Word-audio packs are
separate and unchanged.

Hadith prose and Hadith PDF export use bundled Amiri Naskh (Bold when selected), not the Quran
font's taller metrics. Reading is right aligned, selectable and uses the configured text size with
more compact line spacing. Result previews are bounded; opening a record shows its full Arabic
and the available source translation below it. Hadith translation preference follows the chosen
Quran translation language, with an explicit notice when the existing English fallback is used.

Appearance adds raised text depth, shadow strength/softness, glass-text sheen and glow controls.
Button fill now has its own color, separate from cards and accent highlights. Existing live preview,
undo/redo, saved styles and reduced-effects controls use the same persisted model. Text selection
turns off glyph effects so selection backgrounds do not inherit the text shader. Effects use the
native glyph renderer; they do not rewrite source characters or apply expensive live blur.

## Source audit on 23 September (updated on 24 September)

The missing Arabic vowel marks described below are now resolved using the vocalized files from the
same Open-Hadith-Data revision. The original import selected its plain search-oriented CSVs and
missed the parallel `mushakkala` files. All 62,169 records now import published vowel marks with
exact number/wording validation. See [the follow-up report](HADITH_VOCALIZATION_2026_09.md).
Translations and the wider Sunnah catalog remain incomplete. The following counts describe the
old pack audited on 23 September, not the current vocalized pack.

The checked-in fallback is Open-Hadith-Data, **not Sunnah.com**:

- 62,169 Arabic records across nine collections.
- 0 records with Arabic vowel marks (harakat/superscript alef checked).
- 0 imported English, Urdu or Bangla translations; no Hindi layer is present either.
- Its numbering follows that edition. For example, it has Muslim 556 but not Muslim 5556.

No official Sunnah API credential or authorized offline snapshot is configured here. No website
was mass-scraped, no third-party scraped corpus was relabelled, and no diacritics or translations
were generated. The official developer page requires an API key and describes only partial API
coverage: https://sunnah.com/developers . Therefore even a key must be followed by a coverage
check before claiming a complete Sunnah collection.

The existing `tools/acquire_sunnah_api.py` imports an authorized official snapshot to
`source-vault/hadith/active`, preserving raw responses and hashes. It now converts API HTML body
markup to visible text without stripping vowel marks; the raw response remains archived. The
builder records actual translation and vowel-mark coverage so an Arabic-only pack cannot be
mistaken for a fully vocalized, translated pack. Normal rebuilds use only the committed vault;
no website/API is called by the Hadith reader, search or build.

## Verification

Command (no APK or CI):

```sh
python3 tools/check.py --android-jar /path/to/android-35/android.jar \
  --aapt2 /path/to/build-tools-35/aapt2
```

Passed:

- 132 existing core checks, plus multilingual reference/route/normalization/audio regressions.
- Production reference predicates against a synthetic ambiguous-number fixture and the actual
  62,169-record pack; bare 556 returns nine records, scoped Bukhari 556 returns one.
- Vocalized/plain Arabic example queries both rank the known Bukhari narration first.
- Every one of the 6,236 Quran recitation addresses, including Surah boundaries and last ayah.
- All 18,708 complete translation texts and footnotes equal the archived row at the same
  edition + Surah + ayah coordinate. Samples include Al-Fatiha and 2:255. This checks data
  integrity/alignment; it is not an independent scholarly review of every translation.
- Quran corpus checks: 15/15 retrieval cases, 20 absent queries, 6,236 source-token mappings.
- Offline boundary, database integrity, source hashes, Android resources and Java compilation.

No APK, GitHub workflow, emulator or physical-phone playback/visual test was run. Host timings
are not phone latency promises. Device QA should check rapid query changes, selection, long
Hadith/Urdu reading, preview versus saved effects and downloaded whole-ayah playback.
