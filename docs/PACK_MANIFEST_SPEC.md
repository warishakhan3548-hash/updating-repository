# Content Pack Manifest Spec

A runtime content pack is a derived artifact, never the surviving source of truth. Every pack must be traceable to one **production-approved** Source Vault entry.

Each pack manifest includes:

- `pack_id`, `schema_version`, `content_version`;
- `source_id`, source name/version/edition;
- exact `source_vault_path` and `source_sha256`;
- licence identifier;
- importer version;
- runtime `artifact_path`, `record_count`, `built_sha256`, `built_byte_size`;
- review status;
- dependencies;
- signature metadata;
- when attribution is required, a pack-local `notice_path` and exact `notice_sha256`.

`tools/pack_gate.py` fails closed when the source is not production-approved, when source identity/hash/path/licence drift from the Source Vault registry, or when the built artifact's bytes no longer match its manifest.

For a Source Vault entry with `attribution_required=true`, the manifest must carry both `notice_path` and `notice_sha256`. The notice must be non-empty, resolve inside the same immutable pack-version directory as the manifest (including after symlink resolution), and match the declared SHA-256. The runtime artifact is subject to the same pack-local resolution rule. If optional notice metadata is present for another source, the path/hash pair is still validated together.

`candidate` and `reviewed` packs may be unsigned during development. A pack marked `approved` must carry signature algorithm, key ID and signature value. This creates the release boundary now while allowing the final signing implementation/key-management policy to remain replaceable.

A pack is immutable by content version. Updating a gloss pack must not rebuild unrelated Quran/Hadith packs. Release tooling must reject incompatible dependency mixes and preserve a previous verified pack for rollback.

## Attribution notice gate

When the production Source Vault entry requires attribution, the runtime pack must carry a project-packaged notice file and bind it with `notice_path` plus `notice_sha256`. `tools/pack_gate.py` verifies the notice file and its hash. This prevents a valid evidence source from being repackaged in a way that silently drops required source credit or licence notice obligations.
