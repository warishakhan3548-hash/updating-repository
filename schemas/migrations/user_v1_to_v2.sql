PRAGMA foreign_keys = ON;

BEGIN IMMEDIATE;

DROP TRIGGER IF EXISTS exposure_event_no_update;
DROP TRIGGER IF EXISTS exposure_event_no_delete;
DROP TRIGGER IF EXISTS review_event_no_update;
DROP TRIGGER IF EXISTS review_event_no_delete;

ALTER TABLE exposure_event RENAME TO exposure_event_v1;
ALTER TABLE review_event RENAME TO review_event_v1;

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
  metadata_json TEXT NOT NULL DEFAULT '{}',
  event_schema_version INTEGER NOT NULL DEFAULT 2
    CHECK(event_schema_version >= 1)
);

CREATE TABLE review_event (
  review_event_id TEXT PRIMARY KEY,
  semantic_unit_id TEXT NOT NULL,
  scheduler_adapter TEXT NOT NULL,
  outcome TEXT NOT NULL,
  occurred_at_utc TEXT NOT NULL,
  elapsed_ms INTEGER CHECK(elapsed_ms IS NULL OR elapsed_ms >= 0),
  metadata_json TEXT NOT NULL DEFAULT '{}',
  canonical_grade TEXT
    CHECK(canonical_grade IN ('again', 'hard', 'good', 'easy')),
  scheduler_version TEXT,
  context_ref TEXT,
  event_schema_version INTEGER NOT NULL DEFAULT 2
    CHECK(event_schema_version >= 1)
);

INSERT INTO exposure_event (
  exposure_event_id,
  semantic_unit_id,
  event_type,
  context_ref,
  occurred_at_utc,
  metadata_json,
  event_schema_version
)
SELECT
  exposure_event_id,
  semantic_unit_id,
  event_type,
  context_ref,
  occurred_at_utc,
  metadata_json,
  1
FROM exposure_event_v1;

INSERT INTO review_event (
  review_event_id,
  semantic_unit_id,
  scheduler_adapter,
  outcome,
  occurred_at_utc,
  elapsed_ms,
  metadata_json,
  canonical_grade,
  scheduler_version,
  context_ref,
  event_schema_version
)
SELECT
  review_event_id,
  semantic_unit_id,
  scheduler_adapter,
  outcome,
  occurred_at_utc,
  elapsed_ms,
  metadata_json,
  CASE lower(outcome)
    WHEN 'again' THEN 'again'
    WHEN 'hard' THEN 'hard'
    WHEN 'good' THEN 'good'
    WHEN 'easy' THEN 'easy'
    ELSE NULL
  END,
  NULL,
  NULL,
  1
FROM review_event_v1;

DROP TABLE exposure_event_v1;
DROP TABLE review_event_v1;

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

CREATE TRIGGER exposure_event_v2_require_schema_version
BEFORE INSERT ON exposure_event
WHEN NEW.event_schema_version <> 2
BEGIN
  SELECT RAISE(ABORT, 'new exposure_event rows must use event schema v2');
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

CREATE TRIGGER review_event_v2_require_canonical_fields
BEFORE INSERT ON review_event
WHEN
  NEW.canonical_grade IS NULL
  OR NEW.scheduler_version IS NULL
  OR trim(NEW.scheduler_version) = ''
  OR lower(NEW.outcome) <> NEW.canonical_grade
  OR NEW.event_schema_version <> 2
BEGIN
  SELECT RAISE(
    ABORT,
    'review_event v2 requires canonical grade, matching outcome, scheduler version and event schema v2'
  );
END;

CREATE INDEX idx_exposure_semantic_time
ON exposure_event(semantic_unit_id, occurred_at_utc);

CREATE INDEX idx_review_semantic_time
ON review_event(semantic_unit_id, occurred_at_utc);

CREATE INDEX idx_review_context_time
ON review_event(context_ref, occurred_at_utc);

PRAGMA user_version = 2;

COMMIT;
