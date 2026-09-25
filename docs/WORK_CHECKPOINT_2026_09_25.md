# Active bug-sweep checkpoint — 25 September 2026

Base main: `0330ddd1470567a5fe396e617532c988ca19d529`.
Branch: `audit/bug-sweep-20260925`.

User requested a broad repository bug/UI/UX audit with resumable progress. This branch is the durable handoff point if the chat is interrupted.

## Confirmed finding

Hadith browse/navigation currently performs SQLite reads directly from MainActivity on the UI thread:
- collection -> books
- book -> chapters
- record-page fetch
- single record + translation/grade/reference fetch

The production Hadith pack is large enough that these synchronous reads can cause tap jank or temporary freezes even when indexed. Search already uses background workers, so browse should follow the same lifecycle-safe pattern.

## Planned surgical fix

1. Add a dedicated app-scoped Hadith browse worker.
2. Open sheets immediately with the existing premium loading UI.
3. Fetch browse/detail data off the main thread.
4. Render only if the Activity/view is still live and the browse generation is current.
5. Remove the hidden synchronous translation/grade fallback in search cards.
6. Add static regression checks so MainActivity cannot reintroduce direct HadithStore browse reads on the UI thread.
7. Push changes on this branch and let the existing verification workflow run.

No Quran/Hadith source text, translations, numbering, grading data, or immutable evidence files are to be modified by this audit.
