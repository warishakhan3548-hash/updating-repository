# Content Pack Manifest Spec

Each pack manifest includes:

- pack_id
- schema_version
- content_version
- source name/version/edition
- source_vault_path
- source_sha256
- licence
- importer_version
- record_count
- review_status
- built_sha256
- dependencies
- signature metadata

A pack is immutable by content version. Updating a gloss pack must not rebuild unrelated Quran/Hadith packs. Release tooling rejects incompatible dependency mixes and preserves a previous verified pack for rollback.
