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

## Implemented

- Card surfaces now use real alpha transparency so the backdrop/scene can show through.
- Smart opacity raises only the effective opacity when a high-contrast gradient would otherwise make text unsafe; exact manual behavior remains available by disabling Smart balance.
- Borders strengthen automatically as cards become more transparent.
- Arabic text finishes: Plain, Soft, Glass, Foil. They share one renderer and preserve selection/highlight bypass.
- Arabic shadow supports auto/custom color, angle, distance, softness and strength.
- Background gradients support 0–359° direction.
- Preview shows Arabic/Translation/UI readability grades and whether colors were auto-adjusted.
- Existing Advanced section owns detailed controls; no second advanced UI was added.
- Old saved appearance JSON remains backward-compatible through optional v9 defaults.
- Quran Arabic letter-spacing/tracking was intentionally not added.

## Final verification

- Final code-bearing branch head: `41f02cc61eee0f4fdfb18378a93f6a6a46110558`.
- GitHub Actions push run `36162399509`: SUCCESS.
- Android resource compile + manifest link: PASS.
- Android Java compile: PASS.
- Quran/Hadith integrity, search and audio-boundary regressions: PASS.
- PR #310 was cleanly mergeable and squash-merged.
- Verified squash merge: `4cfd24748af868f653516041eea2845056f77459`.

Status: merged to `main`. Future appearance work should start from current main at/after the verified squash merge above.
