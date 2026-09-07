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
