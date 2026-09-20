PRAGMA foreign_keys = ON;

CREATE TABLE exposure_event (
  exposure_event_id TEXT PRIMARY KEY,
  semantic_unit_id TEXT NOT NULL,
  event_type TEXT NOT NULL CHECK(event_type IN (
    'passive_visible',
    'quick_meaning_opened',
    'deep_morphology_opened',
    'explicitly_unknown',
    'explicitly_known',
    'audio_heard'
  )),
  context_ref TEXT,
  occurred_at_utc TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE review_event (
  review_event_id TEXT PRIMARY KEY,
  semantic_unit_id TEXT NOT NULL,
  scheduler_adapter TEXT NOT NULL,
  outcome TEXT NOT NULL,
  occurred_at_utc TEXT NOT NULL,
  elapsed_ms INTEGER CHECK(elapsed_ms IS NULL OR elapsed_ms >= 0),
  metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE memory_state_cache (
  semantic_unit_id TEXT PRIMARY KEY,
  scheduler_adapter TEXT NOT NULL,
  scheduler_version TEXT NOT NULL,
  state_json TEXT NOT NULL,
  rebuilt_through_utc TEXT NOT NULL
);

CREATE TABLE bookmark (
  bookmark_id TEXT PRIMARY KEY,
  content_ref TEXT NOT NULL,
  created_at_utc TEXT NOT NULL
);

CREATE TABLE note (
  note_id TEXT PRIMARY KEY,
  content_ref TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at_utc TEXT NOT NULL,
  updated_at_utc TEXT NOT NULL
);

CREATE TABLE preference (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL
);

CREATE TRIGGER exposure_event_no_update
BEFORE UPDATE ON exposure_event
BEGIN
  SELECT RAISE(ABORT, 'exposure_event is append-only');
END;

CREATE TRIGGER exposure_event_no_delete
BEFORE DELETE ON exposure_event
BEGIN
  SELECT RAISE(ABORT, 'exposure_event is append-only');
END;

CREATE TRIGGER review_event_no_update
BEFORE UPDATE ON review_event
BEGIN
  SELECT RAISE(ABORT, 'review_event is append-only');
END;

CREATE TRIGGER review_event_no_delete
BEFORE DELETE ON review_event
BEGIN
  SELECT RAISE(ABORT, 'review_event is append-only');
END;

CREATE INDEX idx_exposure_semantic_time
ON exposure_event(semantic_unit_id, occurred_at_utc);

CREATE INDEX idx_review_semantic_time
ON review_event(semantic_unit_id, occurred_at_utc);
