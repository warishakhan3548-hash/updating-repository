# Content Pack Manifest Spec

A runtime content pack is a derived artifact, never the surviving source of truth. Every production pack must be traceable to one **production-approved** Source Vault entry.

The Quran build path is intentionally three-layered:

`Source Vault snapshot → canonical intermediate artifact → runtime content pack`

The exact Source Vault bytes preserve provenance and legal reproducibility. The canonical artifact preserves app-owned semantic identity in a simple deterministic format. The SQLite runtime pack remains an optimized, replaceable delivery format.

## Manifest versions

### Schema v1

Legacy candidate packs bind the runtime artifact directly to a production-approved Source Vault entry. They remain valid for historical verification.

### Schema v2

New packs additionally bind the runtime artifact to a canonical intermediate artifact and record the build toolchain.

Required v2 additions:

- `content_schema_version`;
- `canonical.canonical_id`, canonical version and generator version;
- canonical manifest path and SHA-256;
- canonical artifact path, SHA-256, byte size and record count;
- `build_toolchain.python_implementation`;
- `build_toolchain.python_version`;
- `build_toolchain.sqlite_version`;
- `byte_reproducibility_scope`.

Every pack also keeps:

- `pack_id`, manifest schema version and content version;
- source ID/name/version/edition;
- exact `source_vault_path` and `source_sha256`;
- licence identifier;
- importer version;
- runtime `artifact_path`, `record_count`, `built_sha256`, `built_byte_size`;
- review status;
- dependencies;
- signature metadata;
- required notices and their hashes where a source licence requires them.

`tools/pack_gate.py` fails closed when a source is not production-approved, when source identity/hash/path/licence drift from the Source Vault, when a v2 canonical manifest/artifact no longer matches its recorded hashes or source binding, when notices drift, or when the runtime bytes no longer match the manifest.

## Reproducibility contract

The canonical artifact is the long-lived semantic reproducibility anchor. Its deterministic JSONL representation can be compared byte-for-byte independently of the runtime database library.

A SQLite file's stored SHA-256 is still an integrity requirement for the published pack. However, byte-for-byte regeneration of SQLite is only claimed for the recorded builder/toolchain combination. SQLite's stable file format is relied on for long-term readability and compatibility, not as a promise that every future SQLite/Python build will emit identical physical bytes.

`candidate` and `reviewed` packs may be unsigned during development. A pack marked `approved` must carry signature algorithm, key ID and signature value. A pack is immutable by content version; changed derived bytes require a new content version. Release tooling must reject incompatible dependency mixes and retain a previous verified pack for rollback.
