# Content Pack Manifest Spec

A runtime content pack is a derived artifact, never the surviving source of truth. Every pack must be traceable to one **production-approved** Source Vault entry.

Each pack manifest includes:

- `pack_id`, `schema_version`, `content_version`;
- `source_id`, source name/version/edition;
- exact `source_vault_path` and `source_sha256`;
- licence identifier;
- source attribution/link and a notice path/hash when redistribution terms require attribution;
- importer version;
- runtime `artifact_path`, `record_count`, `built_sha256`, `built_byte_size`;
- review status;
- dependencies;
- signature metadata.

`tools/pack_gate.py` fails closed when the source is not production-approved, when source identity/hash/path/licence drift from the Source Vault registry, or when the built artifact's bytes no longer match its manifest. For attribution-required sources, the gate also verifies that the notice lives inside the same pack directory and that its SHA-256 matches the manifest.

`candidate` and `reviewed` packs may be unsigned during development. A pack marked `approved` must carry signature algorithm, key ID and signature value. This creates the release boundary now while allowing the final signing implementation/key-management policy to remain replaceable.

A pack is immutable by content version. Updating a gloss pack must not rebuild unrelated Quran/Hadith packs. Release tooling must reject incompatible dependency mixes and preserve a previous verified pack for rollback.
