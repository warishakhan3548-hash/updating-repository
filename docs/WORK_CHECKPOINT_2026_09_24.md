# Resumable Hadith vocalization checkpoint

Base main: `8d5ac3787849fab5f291145ac16b62a0492dec4c` (PR #268).
Branch: `codex/vocalized-hadith-20260924`.

User explicitly requested downloading vocalized Hadith from another source if Sunnah access was
unavailable, storing it in their GitHub repository, and fixing the offline app. Published source
text was found, so no generated diacritics are needed. No APK or CI run is authorized by this task.

The same pinned Open-Hadith-Data revision includes nine vocalized CSVs. All 62,169 records have
source vowel marks and match the old collection/number/wording after ignoring marks and layout
whitespace. Original gzip archives, provenance and importer changes are in this branch. See
[the source report](HADITH_VOCALIZATION_2026_09.md) for the exact dataset and limits.

Verification complete: `tools/check_hadith.py` passed all 62,169 archived-source text/identity
comparisons plus invalid-input fixtures; `tools/check.py` passed core, search, Quran and translation
regressions. Local logs: `build/vocalized-verification.log`, `build/vocalized-core-check.log`.
Per-file GitHub upload checkpoints are in `build/github-vocalized-blobs.json`; these temporary
logs are not part of the app and are not committed. Use the published Git tree after completion.

Before resuming, inspect git status/log and the GitHub branch. Do not re-download archived source
or redo completed commits. Finish verification/publication only if absent. Source preparation and
all builds use committed files and need no source website or API key. Hadith translations and
phone QA remain separate work; do not call the source Sunnah.com or invent those translations.
