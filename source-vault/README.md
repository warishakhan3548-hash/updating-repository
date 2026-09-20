# Source Vault

This directory is a gate, not a dumping ground.

No critical dataset becomes a production dependency until its exact artifact is legally preservable, copied here (or to a project-controlled immutable large-file mirror), hashed and accompanied by licence/provenance.

The current registry has one production-approved evidence source: the exact pinned Tanzil Quran Text v1.1 Uthmani snapshot. Other Quran gloss, morphology, Hadith, font, timing, translation, or audio-metadata candidates remain non-production until they independently pass the same gate.

When a large artifact is stored outside normal Git, its registry entry must still identify the project-controlled immutable location and checksum. Normal builds consume that preserved version, never an upstream "latest" URL.

Network acquisition and Source Vault promotion are separate operations. Acquisition tooling may stage exact upstream bytes for review; it must not silently update the registry, create a release pack, or mark a source `production-approved`.
