# App-wide UI and date-entry upgrade

Baseline: main at a713651da82017f95cf284246af19c4e355ff7cd.
Work is on main. No application build, dependency bootstrap or CI dispatch.
Checkpoint commits use [skip ci] because main has a push-triggered APK workflow.

## Dependency and state map (before implementation)

- main.dart opens SqliteInventoryStorage, initializes PharmacyController and
  passes the same controller to PharmacyApp / the five-tab shell.
- The controller owns the inventory snapshot, day refresh, warning settings,
  revisions, search worker, sales, tracking, imports, history and backup actions.
- domain/medicine.dart owns strict ISO civil dates and medicine invariants;
  inventory.dart derives scopes, countdowns and counters; search.dart and
  tracking.dart derive search matches, movement and reorder suggestions.
- ui/design.dart is the shared theme, surfaces, medicine cards and status border.
  Every screen imports it. Changes here affect the entire visual language.
- Home taps open SearchScreen with an existing scope; typing/mic/barcode/OCR
  reach the same search engine; a result opens EditorScreen with the record ID.
- Editor forms create a Medicine draft, then controller.save checks revisions
  and persists atomically. Notifications refresh every derived view.
- ImportCenter -> Scanner/media/text -> ImportInbox -> reviewed editor draft.
- AI -> provider/export -> response validation -> selected diff -> controller
  apply. Backup -> review -> typed confirmation -> restore. Both retain guards.
- Calculator -> tracking period -> metrics/reorder -> editable OrderScreen ->
  native PDF sharing. Profile -> settings/activity/removed/backup/export.

## Surgical changes

| UI entry point | Input/action | State / result |
| --- | --- | --- |
| Expiry and MFG | digits or calendar | shared date formatter -> validated ISO draft |
| Sale and custom tracking dates | same formatted fields | existing sale/range APIs |
| Home | four equal status cards, then Scan & Search | original live scopes |
| All screens | shared depth, spacing, readable actions | existing navigation preserved |
| Editor | grouped fields, clear save and stock actions | existing record/save/history rules |
| AI / imports / backup | numbered instructions and visible review actions | original review gates |

Date storage, AI exchange and backup JSON stay ISO. Month-only expiry retains
its last-day-of-month semantics. The input layer must reject invalid dates,
retain cursor/selection edits, support deletion and respect IME composition.
Existing search precision, expired-stock reorder exclusions and stale-write
protections on main must be retained.

Sources consulted: Flutter TextInputFormatter, Flutter accessibility/design and
GitHub skipping-workflow-runs documentation. Validation status is recorded at
completion; screenshot parity and Android runtime behavior require a later run.

## Completed source changes

- Home shows four equally sized green/mint/yellow/red status cards before the
  global Scan & Search action. Card height is measured from the actual text scale;
  large counts remain complete. The medicine total remains below the scan action.
- The original shared theme and surfaces provide gradients, depth, readable
  fields, tap feedback, consistent buttons, dialogs and rounded navigation.
- Search retains its scopes, fuzzy ranking, mic, barcode/OCR and bulk list flows.
  Its header scrolls with lazy results, keeping actions reachable with a keyboard.
- Editor fields are grouped into medicine, dates/stock, location/notes and scan
  details. Save stays available at the bottom; history, restock, sale, SOLD,
  archive and discard guards are retained.
- All expiry/MFG/sale/tracking date input uses automatic slashes, a numeric
  keyboard and calendar selection. Expiry offers MM/YYYY and DD/MM/YYYY.
  Formatting handles selections, backspace, ISO paste and Hindi/Arabic/full-width
  digits. Partial-date errors wait until leaving the field or submitting.
- AI, imports/review, orders/PDF and backup/restore show clear step labels.
  Calculator, profile, activity and version history use the same visual system.
  Camera results show the complete captured evidence in a scrollable preview;
  scanner and voice layouts also scroll on short screens or large text.
- Visited main tabs retain their draft/query/period state. Tabs initialize lazily;
  inactive tab tickers are disabled. A changed controller clears cached pages.

## Verification and limits

- Existing pure-Dart inventory contract: 45 passed, 0 failed.
- New pure-Dart date-input contract: 24 passed, 0 failed. Includes invalid days,
  leap years, month end, ISO round trips and manufacturing/expiry ordering.
- Static analysis: no issues in the 14 selected UI/app/date files (all UI files
  except scanner_screen.dart and voice_sheet.dart, plus app.dart and date_input).
  Static analysis of scanner/voice is limited by missing camera/ML Kit/speech
  packages in this checkout. No packages were downloaded.
- All changed Dart files pass formatter parsing; git diff --check is clean.
- Eight Flutter formatter interaction tests were added for typing, deleting,
  pasting, range replacement and IME composition. They were not executed here.
- No Flutter test run, application launch, APK build, dependency bootstrap or
  workflow dispatch was performed. Existing backend/services and build workflows
  are unchanged. Device layout, keyboard, camera and voice behavior need the
  owner's subsequent run; exact screenshot parity is not claimed.

Primary references:

- https://api.flutter.dev/flutter/services/TextInputFormatter-class.html
- https://docs.flutter.dev/ui/accessibility
- https://docs.flutter.dev/ui/accessibility/ui-design-and-styling
- https://docs.github.com/actions/managing-workflow-runs/skipping-workflow-runs
