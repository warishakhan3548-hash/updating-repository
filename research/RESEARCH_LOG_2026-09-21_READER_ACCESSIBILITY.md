# Research Log — Reader Accessibility Semantics — 2026-09-21

Purpose: improve the minimal offline Quran reader for screen-reader and large-text users without adding UI complexity, changing Quran evidence, or reintroducing an unverified word-tap affordance.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Jetpack Compose semantics are consumed by accessibility services and the Compose testing framework. | https://developer.android.com/develop/ui/compose/accessibility/semantics | 2026-09-21 | High | Treat semantics as part of the reader contract, not decorative metadata. |
| fact | Compose exposes a `heading()` semantic so assistive technologies can navigate text-heavy screens by headings. | https://developer.android.com/develop/ui/compose/accessibility/semantics#headings | 2026-09-21 | High | Mark the reader title and Surah chooser title as headings. |
| fact | `liveRegion = LiveRegionMode.Polite` is intended for important changing status/notification content; assertive announcements should be used sparingly and frequently changing content should not be made live. | https://developer.android.com/develop/ui/compose/accessibility/semantics#alerts-pop-ups | 2026-09-21 | High | Announce completed error/no-result states politely, but do not make the every-keystroke search/loading cycle an assertive live region. |
| fact | Compose provides an `error` semantic to convey error-state information to accessibility services. | https://developer.android.com/develop/ui/compose/accessibility/semantics#error-components | 2026-09-21 | High | Attach error semantics to reader-load and search failures. |
| fact | Android/Material guidance uses a 48dp minimum interactive target, and Compose provides minimum-target behavior around interactive components. | https://developer.android.com/reference/kotlin/androidx/compose/ui/Modifier#minimumInteractiveComponentSize() | 2026-09-21 | High | Preserve the existing explicit 48dp floor on reader controls. |
| fact | Android scalable pixels (`sp`) incorporate the user's font-size preference. | https://developer.android.com/design/ui/mobile/guides/layout-and-content/grids-and-units | 2026-09-21 | High | Keep Quran and result typography in `sp`; do not hard-code text size in `dp`. |
| fact | WCAG 2.2's resize-text guidance calls for text enlargement without loss of content/functionality. | https://www.w3.org/WAI/WCAG22/Understanding/resize-text.html | 2026-09-21 | High | Use this as a cross-platform review target, but do not claim conformance until Android large-font/device testing is performed. |

## Decision

Keep the visible reader unchanged and improve the semantic layer:

1. mark the top-level Quran title and Surah chooser title as headings;
2. give indeterminate Quran-load and search progress indicators contextual accessible labels;
3. expose reader/search failures with the Compose `error` semantic plus a polite live region;
4. make the completed no-result message a polite live region;
5. preserve the visible **Approximate spelling match** label and also expose it as the result button's state description;
6. retain 48dp interactive floors, source-faithful RTL rendering, and `sp` typography;
7. do not manually override traversal order while natural composition order remains correct;
8. do not restore UI-only word tapping before provenance-backed word details exist.

## Validation boundary

Static regression tests can protect the semantic contract and Android lint/build can catch API misuse. They do **not** prove real TalkBack quality, 200% text-scale usability, switch-access behavior, focus order on every device, or low-end performance. Those remain explicit device-validation work; no device result is claimed in this milestone.

No external content dataset, Source Vault artifact, Quran byte, canonical record, content pack, or search index changes in this milestone.
