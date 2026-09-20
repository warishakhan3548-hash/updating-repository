# Accessibility and Performance

## Accessibility baseline

- RTL-first semantics for Arabic reading.
- Screen-reader labels expose surah/ayah context without reading hidden normalized text.
- Important Android controls use at least 48dp focus/touch areas.
- Text uses scalable units and must remain usable without clipping at large user font scales; color is never the only status signal.
- Do not expose a gesture-only word action. Word help stays hidden until verified content exists and the same action can be reached through accessibility focus/custom actions as well as touch.
- Respect reduced-motion preferences.

## Implemented Phase 1 reader semantics

- The main Quran title and Surah chooser title are marked as accessibility headings.
- Quran-load and Quran-search progress indicators expose contextual labels instead of an unlabeled spinner.
- Reader-load and search failures use Compose error semantics and a polite live region.
- The completed **No reliable match found** state is a polite live region; transient loading is not made assertive.
- **Approximate spelling match** remains visible text and is also exposed as semantic state, so confidence is not communicated by color alone.
- The reader keeps explicit 48dp interactive-height floors, `sp` Quran typography and content-driven RTL.
- `tests/test_android_reader_accessibility.py` protects these contracts and also prevents accessibility work from restoring the unavailable word-tap gesture.

These static/build checks are not a substitute for TalkBack, Switch Access, large-font and device testing.

## Performance measurement

Do not invent achieved numbers. Benchmark representative low-end Android hardware for cold start, Quran render, future word-help response, search latency, memory usage and scroll smoothness.

Prewarm only nearby word information when profiling proves it useful. Search and ranking work must be cancellable and kept off the UI thread where necessary.
