# Aaris Pharmacy: researched redesign and voice repair

Baseline: `c9de01baee711cfa79ed6f8fdd7a0ece24ea22a2`, repository
`warishakhan3548-hash/updating-repository`, branch `main`.

## Architecture before editing

- `main.dart` opens SQLite and initializes one `PharmacyController`.
- `app.dart` retains five lazily initialized tabs: Home, Database, AI,
  Calculator, Profile. Every route shares `ui/design.dart`.
- `data/inventory_database.dart` commits stock facts, settings and history.
  `domain/inventory.dart` derives expiry/status/counts; `domain/search.dart`
  ranks matches; `services/search_worker.dart` runs expensive ranking off UI.
- Home card -> `SearchScreen(scope)` -> controller search -> exact stock ID ->
  `EditorScreen` -> revision-checked save -> SQLite -> controller notification ->
  all live views refresh. Typed, voice and scan inputs converge on this path.
- `voiceSearch` opens a modal -> shared `SpeechToText` -> partial/final text ->
  explicit search confirmation -> `SearchScreen._setQuery`. It never writes stock.
- Camera -> local barcode/OCR -> search. Optional catalog candidates -> reviewed
  identity-only draft. AI/import/backup review gates remain unchanged.
- Surgical targets: original shared visual primitives and theme, overview tiles,
  scanner colors, search action affordances, and microphone session ownership.
  Storage schemas, expiry calculations, search ranking and review rules are not
  redesign targets.

## Research scope and evidence

Searched Dribbble for all ten requested topics: premium pharmacy app UI; medical
inventory mobile app; healthcare dashboard mobile UI; inventory management app
UI; medicine scanner UI; barcode scanner mobile UI; AI assistant mobile app UI;
modern glassmorphism mobile app; 3D mobile dashboard UI; premium dark light
healthcare app. Narrow exact phrases were broadened when no direct shots matched.

Primary inspiration:

- [Medical Inventory Management, Fazlur Rahman](https://dribbble.com/shots/27037156-Medical-Inventory-Management-App): inspected two full image boards. Strong mobile summary hierarchy, reusable rows, restrained accents, rounded panels. Public listing showed roughly 96 likes / 6.3k views; these are discovery signals, not usability evidence.
- [Inventory management search](https://dribbble.com/search/inventory-management-app-ui): Nixtio and VALMAX appeared with roughly 461 / 273 likes. Repeated pattern: large counts, compact operational cards, easy access to stock search.
- [Stockly](https://dribbble.com/shots/26809840-Stockly-Inventory-Management-App-UI-Kit): published description covers one design system across inventory, scanning and light/dark variants. Referenced coverage; did not buy or copy the kit.
- [Barcode scanner references](https://dribbble.com/search/barcode-scanner): focused viewfinder, concise controls, explicit result handoff.
- [AI assistant references](https://dribbble.com/search/ai-assistant): distinct input/status/action hierarchy. AI remains a reviewed inventory workflow here.
- [Healthcare Companion dark theme](https://dribbble.com/shots/16631635-Healthcare-Companion-App-Dark-Mode), [3D concept](https://dribbble.com/shots/27062529-3D-Mobile-App-UI-Concept), and [glass references](https://dribbble.com/search/glassmorphism-mobile-app): depth can support hierarchy, but large multicolor glows and transparent text surfaces are unsuitable for dense medicine data.

Behance case studies:

- [Pharma Fast](https://www.behance.net/gallery/225692587/PHARMA-FAST-APP-ITI-Graduation-(UIUX-Case-Study)): inspected its multi-module case study and component board in browser, including repeated product cards, expanded/collapsed FAQ states, stock and action states. It shows a reusable system and end-to-end screens. Customer ordering is not adopted into the pharmacy-owner app.
- [KwikMedi](https://www.behance.net/gallery/245739779/KwikMedi-Healthcare-Delivery-App-UX-Case-Study): public case-study description includes research, flows, wireframes and a design system.
- [Truemeds](https://www.behance.net/gallery/247541717/Truemeds-Pharmacy-App-UX-Case-study): navigation and selection uncertainty motivate visible scopes and confidence labels, not automatic medicine substitution.

Mobbin production references (public indexed descriptions):

- [Apple Health summary](https://mobbin.com/explore/screens/5e311abb-f8f6-4e0b-9d44-a03671426672): priority data cards and clear editing affordance.
- [Noom search](https://mobbin.com/explore/screens/48ce175a-9031-4862-8bb1-880d66e5f8d1): one search entry with barcode and create alternatives.
- [LookUp search](https://mobbin.com/explore/screens/c1307983-c40e-4a19-bff4-dd9a53a7c8f3): scanning adjacent to text search.
- [Tab bar glossary](https://mobbin.com/glossary/tab-bar): stable top-level destinations, at most five recommended.
- [Scanning flows](https://mobbin.com/explore/mobile/flows/scanning): capture followed by result/review.

The live Mobbin screen returned a plain 403 Forbidden in this browser. Full
interactive Mobbin inspection is not claimed. Public saves were unavailable;
no save counts or research success metrics are invented.

## Original design decision

Sapphire primary, teal secondary, blue-grey canvas, opaque white content surfaces,
navy text. Red/amber/green retain stock meaning and text labels. One Manrope /
Noto Sans Devanagari type system, 4px spacing rhythm, 16px controls and 22px cards,
48px primary touch targets, restrained shadows. Glass is reserved for a small
navigation surface; list/form surfaces avoid repeated blur. Four equal overview
cards precede Scan & Search. Every screen uses the same tokens, including AI,
backup, scanner and voice. This is a synthesis, not a copy of a reference screen.

## Microphone findings and repair contract

The existing sheet forces `onDevice: true`, which can prevent recognition without
an installed offline language pack. It also disables retry after failed init,
allows actions during asynchronous startup, and has no ownership coordination
between modal lifetimes. Error/status callbacks are not session-scoped. A normal
silence/no-match is presented as speech being unavailable.

Repair: device-default recognition with truthful online/offline wording; one
modal owner; serialized start/stop/cancel; generation checks for late results;
explicit ready/starting/listening/finishing/error states; language IDs taken from
the actual device; permission retry; preserve recognized words on stop; cancel
and detach listeners when leaving. Never automatically search or change stock.

Technical primary reference: https://pub.dev/packages/speech_to_text/versions/7.4.0
and its versioned API documentation. Device recognition quality and installed
language support must still be verified on a physical Android device.

## Checkpoints

1. Baseline inspected and research/state map recorded. Implementation follows.
