# Resumable work checkpoint

Superseded for Hadith source work by [the 24 September checkpoint](WORK_CHECKPOINT_2026_09_24.md).
PR #268 was merged as `8d5ac3787849fab5f291145ac16b62a0492dec4c`. The plain-only limitation below
was the old import selection, not a limitation of the upstream repository; its vocalized files
are now archived and imported by the follow-up work.

Base: `4e295a1c3f17297a8600887bd585e14fd4a2755d`.
Branch: `codex/offline-search-reading-20260923`.
First remote checkpoint: `135afea841cc68219c47dea9fc2c5d627c255ac3`.

User authorized implementation, repository persistence and resumable checkpoints. No CI or APK
build. Full repository/history was cloned. Read git status and
`docs/SEARCH_READING_FIXES_2026_09.md` before resuming; do not restart acquisition or rewrite source.

Completed: coordinate-validated recitation and cache invalidation; shared Quran/Hadith search;
multilingual collection/reference intent; Arabic normalization/index parity; Naskh Hadith layout;
translation alignment verification; appearance depth/shadow/glass/button controls; source-import
markup handling and actual coverage metadata. Native compilation and local regression checks pass.

The official Sunnah.com source import is still blocked by missing API access/authorized snapshot.
The fallback has 62,169 Arabic records, zero vowel-marked records and zero source translations.
Never call the fallback Sunnah data or claim that new fonts added source harakat. The existing
Sunnah importer requires an operator-supplied credential and offline redistribution evidence.
No credential may be committed. All source material needed by a completed import must be
committed before claiming website-independent future rebuilds.

Next: finish final repository publication/PR if absent. Then obtain authorized official source
access to complete the remaining content request; phone playback and visual QA remain pending.
