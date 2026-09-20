# Accessibility and Performance

## Accessibility baseline

- RTL-first semantics for Arabic reading.
- Screen-reader labels expose surah/ayah context without reading hidden normalized text.
- Important Android controls use at least 48dp focus/touch areas.
- Text scales without clipping; color is never the only status signal.
- Every gesture has a discoverable single-pointer/control alternative.
- Respect reduced-motion preferences.

## Performance measurement

Do not invent achieved numbers. Benchmark representative low-end Android hardware for cold start, Quran render, word-tap response, search latency, memory usage and scroll smoothness.

Prewarm only nearby word information when profiling proves it useful. Search and ranking work must be cancellable and kept off the UI thread where necessary.
