# Smart Appearance Editor checkpoint — 25 September 2026

Base main: `643fc02c1f0cb5853034a619651920719eec8458`.
Working branch: `upgrade/smart-appearance-editor-20260925`.

## Dependency tree

`MainActivity.appearanceStudio()`
→ `AppearanceStudio` (editor UI + live preview)
→ `Appearance` (persisted visual model + contrast/readability)
→ `Glass.Backdrop / Glass.Surface` (background, cards, borders)
→ `ArabicText` (Arabic finish, sheen, shadow/glow)
→ `QuranText` (word spans/highlights; shaping must remain untouched)

## Upgrade rules

- Preserve Android Arabic shaping and Quran word spans. No letter-spacing/tracking.
- Keep all source/evidence content untouched.
- Real card transparency must remain readable over both background gradient endpoints.
- Decorative effects must remain deterministic/offline and lightweight for low-RAM Android.
- Existing saved themes must decode with backward-compatible defaults.
- Selection/highlight mode must bypass decorative Arabic shaders/shadows as before.

## Planned changes

- True lightweight card transparency with smart border compensation.
- Text finish modes: Plain, Soft, Glass, Foil, integrated into the existing single-pass Arabic renderer.
- Directional shadow with auto/custom color, angle and distance.
- Gradient angle.
- Always-on readability protection plus visible AA/AAA status in preview.
- Auto-balance for decorative effects without replacing the user's chosen palette.
- Regression assertions for persistence, renderer safety, and transparent-surface logic.

Status: implementation in progress.
