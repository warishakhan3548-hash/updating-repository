# Active bug-sweep checkpoint — 25 September 2026

Base main: `0330ddd1470567a5fe396e617532c988ca19d529`.
Working branch: `audit/bug-sweep-20260925`.

The user requested a broad repository bug/UI/UX audit with durable recovery if the chat is interrupted.
Resume from this branch and this file, not from an old local clone.

## Confirmed bugs fixed

### 1. Hadith browse SQLite work was running on the Android UI thread
Affected flows included collection -> books, book -> chapters, record pagination, record detail,
translation/grade/reference lookups, confirmed-search shortcut validation, and the research comparison preview.

Fix:
- Added an app-scoped single-thread `hadithBrowseWorker`.
- Hadith sheets open immediately with the existing premium loading UI.
- Books, chapters, records, detail metadata, and compare metadata now load off the UI thread.
- Generation + attached-view guards prevent stale callbacks from repainting a closed/replaced sheet.
- Activity destruction cancels the current browse future and invalidates its generation.
- Search cards no longer contain a hidden fallback that can query translations/grades on the UI thread.
- Saved Hadith shortcuts are already scoped by the immutable pack hash, so the redundant UI-thread
  existence query was removed.
- Added regression checks in `tools/check.py` for these non-blocking paths.

Primary commits:
- `7e9f39d6e88affe3f1cfa8c737cb0ca458d073a3`
- `84df30e21198ee475c172a1dcfd06a362e909bf5`
- `46387002696ee94ea5d5991fe6c9116e27c256a3`
- `6dc669d1902f2d272cfe77c013048df49c5a5b34`

### 2. Ambient recall candidate construction could do N+1 source/settings reads on the main service thread
Fix:
- Candidate validation/retrieval now runs on the existing background reader worker.
- Reading language is loaded once per candidate pass instead of once per saved item.
- Word targets use one direct source lookup instead of validation followed by a duplicate word lookup.
- Results are only shown if the session is still running, visible-eligible, and still waiting for that card.
- Session restarts/destroy invalidate stale candidate callbacks.

Commits:
- `36484fc310c436112f3b2b8543b16a3ff0b64617`
- `ccda24018e8c8971d2b33825ee3f3a9673a6dbb0`

### 3. Ambient notification instruction did not match its action
The notification said "Tap to stop", but tapping it opens Aaris to manage the session; Stop is a separate
notification action. Copy now says "Tap to manage".

Commit: `4d63985303047a2ee6c5c7b6284151dd0cbe2ded`.

### 4. Verification depended on source-branch naming
The workflow originally ran only on `upgrade/**` pushes. Audit branches were added first, then the
workflow was hardened to run for every pull request targeting `main` when relevant code/data changes.

Commits:
- `e1f85a32f27b15c7086448791ffe8e0d43d62a2a`
- `fba47582bd45137af98cb037afc324ef381e56a5`

### 5. Quran empty-result copy contradicted long-query support
"No Quran text match. Try a shorter phrase." was replaced with wording that does not imply long pasted
queries are unsupported.

Included in `84df30e21198ee475c172a1dcfd06a362e909bf5`.

## Verification evidence

- Branch workflow run for `6dc669d1902f2d272cfe77c013048df49c5a5b34` completed successfully:
  evidence rebuild, offline integrity/search regressions, Android Java compile/resource validation,
  and Hadith checks all passed.
- The later ambient/workflow commits require the final-head workflow/PR run before merge.
- Structural brace scan of the modified MainActivity/QuranApp sources found no unmatched Java blocks.

## Audit notes / limits

- RecitationService foreground startup, audio-focus generation guards, cancellation, and worker handoff
  were reviewed; no confirmed regression was found in that pass.
- Word-audio and reciter download paths were reviewed for reservation/cancel/resume state. No speculative
  refactor was made where an actual defect was not demonstrated.
- Real-device visual, OEM overlay, media playback, storage-corruption, and low-memory QA remain device tests;
  CI/host compilation cannot honestly certify them.

## Resume order

1. Inspect the latest Actions run for this branch; fix any failure before publication.
2. Create/update the PR from `audit/bug-sweep-20260925` to `main`.
3. Require the PR-to-main verification run to pass.
4. Review the final diff, then merge without changing Quran/Hadith source text or evidence data.
5. Continue the audit only from new concrete findings; do not layer speculative wrappers over working code.
