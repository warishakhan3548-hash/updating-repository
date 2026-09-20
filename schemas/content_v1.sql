PRAGMA foreign_keys = ON;

CREATE TABLE pack_metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE source_assertion (
  source_assertion_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  source_version TEXT NOT NULL,
  source_sha256 TEXT NOT NULL CHECK(length(source_sha256) = 64),
  assertion_type TEXT NOT NULL,
  payload_json TEXT NOT NULL
);

CREATE TABLE quran_ayah (
  ayah_id TEXT PRIMARY KEY CHECK(ayah_id GLOB 'qa:[0-9][0-9][0-9]:[0-9][0-9][0-9]'),
  surah INTEGER NOT NULL CHECK(surah BETWEEN 1 AND 114),
  ayah INTEGER NOT NULL CHECK(ayah >= 1),
  original_text TEXT NOT NULL,
  search_unicode TEXT NOT NULL,
  search_diacritic_free TEXT NOT NULL,
  source_assertion_id TEXT NOT NULL REFERENCES source_assertion(source_assertion_id),
  UNIQUE(surah, ayah)
);

CREATE TABLE quran_token (
  token_id TEXT PRIMARY KEY,
  ayah_id TEXT NOT NULL REFERENCES quran_ayah(ayah_id),
  token_index INTEGER NOT NULL CHECK(token_index >= 1),
  original_text TEXT NOT NULL,
  search_text TEXT NOT NULL,
  UNIQUE(ayah_id, token_index)
);

CREATE TABLE quran_segment (
  segment_id TEXT PRIMARY KEY,
  token_id TEXT NOT NULL REFERENCES quran_token(token_id),
  segment_index INTEGER NOT NULL CHECK(segment_index >= 1),
  original_text TEXT NOT NULL,
  morphology_json TEXT,
  source_assertion_id TEXT REFERENCES source_assertion(source_assertion_id),
  UNIQUE(token_id, segment_index)
);

CREATE TABLE lexeme (
  lexeme_id TEXT PRIMARY KEY,
  canonical_label TEXT NOT NULL,
  root TEXT,
  lemma TEXT,
  verb_form TEXT,
  mapping_rule_version TEXT NOT NULL
);

CREATE TABLE sense (
  sense_id TEXT PRIMARY KEY,
  lexeme_id TEXT NOT NULL REFERENCES lexeme(lexeme_id),
  language TEXT NOT NULL,
  contextual_gloss TEXT NOT NULL,
  provenance TEXT NOT NULL
);

CREATE TABLE hadith_edition (
  edition_id TEXT PRIMARY KEY,
  collection_name TEXT NOT NULL,
  bibliographic_label TEXT NOT NULL,
  source_version TEXT NOT NULL,
  numbering_system TEXT NOT NULL,
  source_assertion_id TEXT NOT NULL REFERENCES source_assertion(source_assertion_id)
);

CREATE TABLE hadith_record (
  hadith_record_id TEXT PRIMARY KEY,
  edition_id TEXT NOT NULL REFERENCES hadith_edition(edition_id),
  source_record_key TEXT NOT NULL,
  book_label TEXT,
  chapter_label TEXT,
  number_label TEXT,
  original_arabic TEXT NOT NULL,
  isnad_original TEXT,
  matn_original TEXT NOT NULL,
  search_exact TEXT NOT NULL,
  search_matn_diacritic_free TEXT NOT NULL,
  search_isnad_diacritic_free TEXT,
  search_orthographic TEXT NOT NULL,
  UNIQUE(edition_id, source_record_key)
);

CREATE TABLE citation (
  citation_id TEXT PRIMARY KEY,
  hadith_record_id TEXT NOT NULL REFERENCES hadith_record(hadith_record_id),
  display_citation TEXT NOT NULL
);

CREATE TABLE grade_assertion (
  grade_assertion_id TEXT PRIMARY KEY,
  hadith_record_id TEXT NOT NULL REFERENCES hadith_record(hadith_record_id),
  grade_text TEXT NOT NULL,
  grader TEXT NOT NULL,
  source TEXT NOT NULL,
  source_version TEXT NOT NULL
);

CREATE TABLE occurrence (
  occurrence_id TEXT PRIMARY KEY,
  lexeme_id TEXT NOT NULL REFERENCES lexeme(lexeme_id),
  sense_id TEXT REFERENCES sense(sense_id),
  quran_token_id TEXT REFERENCES quran_token(token_id),
  hadith_record_id TEXT REFERENCES hadith_record(hadith_record_id),
  confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
  CHECK((quran_token_id IS NOT NULL) != (hadith_record_id IS NOT NULL))
);

CREATE TABLE narration_cluster (
  cluster_id TEXT PRIMARY KEY,
  method_version TEXT NOT NULL
);

CREATE TABLE narration_cluster_member (
  cluster_id TEXT NOT NULL REFERENCES narration_cluster(cluster_id),
  hadith_record_id TEXT NOT NULL REFERENCES hadith_record(hadith_record_id),
  confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
  PRIMARY KEY(cluster_id, hadith_record_id)
);

CREATE INDEX idx_quran_token_ayah ON quran_token(ayah_id, token_index);
CREATE INDEX idx_occurrence_lexeme ON occurrence(lexeme_id);
CREATE INDEX idx_hadith_record_edition ON hadith_record(edition_id);
CREATE INDEX idx_grade_hadith ON grade_assertion(hadith_record_id);
