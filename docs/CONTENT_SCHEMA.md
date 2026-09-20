# Content Schema

`schemas/content_v1.sql` defines the canonical relational shape.

## Evidence Plane
Quran ayahs/tokens/segments, Hadith records, citations, grade assertions and source assertions preserve original source text and metadata. Original display fields are separate from every search-normalized field.

## Lexical model
`Lexeme → Sense → Occurrence`

A lexeme represents a lexical family. A sense represents a context meaning. An occurrence connects a Quran token or Hadith location to the appropriate sense.

Morphology from external sources is kept as attributed data/mappings; corrections are overlays rather than edits to archived raw bytes.

Runtime content packs are replaceable. They must never be the only surviving source copy.
