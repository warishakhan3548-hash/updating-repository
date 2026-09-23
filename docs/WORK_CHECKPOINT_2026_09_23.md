# Search, reading and recitation checkpoint

Base: `4e295a1c3f17297a8600887bd585e14fd4a2755d`.
Branch: `codex/offline-search-reading-20260923`.

User authorized implementation, repository persistence and resumable checkpoints. Do not run CI
or build an APK. Read this file and git status before continuing after interruption.

Completed code (verification pending):
- Recitation addresses are validated against Quran coordinates and converted to 1-based IDs.
  A new cache namespace prevents the old one-ayah-shifted downloads from being reused.
- Hadith query parser accepts multilingual collection names, references, spaced individual digits
  and suffix variants. Reference lookup is separate from text ranking and scoped at SQL retrieval.
- Search shadows handle presentation forms, bidi controls, Arabic vowel marks and Unicode digits;
  source Arabic remains unchanged. The local Hadith builder has matching normalization/indexes.

Remaining:
- One shared Quran/Hadith search UI, Hadith typography and Appearance effect controls.
- Actual-corpus checks, translation coordinate/content review, native compilation if tools available.
- Review, final commit and PR targeting main.

Source prerequisite (do not invent content or claim completion):
The repository contains Open-Hadith-Data Arabic (62,169 records), not a Sunnah.com corpus.
No SUNNAH_API_KEY or authorized Sunnah offline snapshot is available in this environment.
The official API requires a key and covers a portion of the site. Full vocalized Arabic/translation
acquisition is still pending. Existing source-vault/hadith/active import support is retained;
no fabricated harakat, translation or cross-edition numbering is acceptable.
