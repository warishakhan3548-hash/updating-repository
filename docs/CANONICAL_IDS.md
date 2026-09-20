# Canonical IDs

Canonical IDs are app-owned and stable across replaceable libraries.

- Ayah: `qa:<surah-3d>:<ayah-3d>`, e.g. `qa:002:255`
- Token: `qt:<surah-3d>:<ayah-3d>:<token-3d>`
- Segment: `qs:<surah-3d>:<ayah-3d>:<token-3d>:<segment-2d>`
- Lexeme: `lx:<uuid>`
- Sense: `sn:<uuid>`
- Grammar bit: `gb:<uuid>`
- Edition: `ed:<uuid>`
- Hadith record: `hr:<uuid>`
- Citation: `ci:<uuid>`
- Grade assertion: `ga:<uuid>`
- Narration cluster: `nc:<uuid>`
- Exposure event: `xe:<uuid>`
- Review event: `rv:<uuid>`

Third-party row IDs are mappings, never sole identity. A Hadith record is edition-specific; parallel narrations remain separate records.
