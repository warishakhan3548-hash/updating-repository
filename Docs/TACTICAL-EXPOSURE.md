# Tactical exposure map — offline authoring diagnostic

A playable battle-royale map is more than a large number of buildings and trees. Cover, clear approach routes, contested height and legible location choices matter. Official Free Fire Bermuda reworks and PUBG developer updates motivate a measurable review workflow. This implementation is original Aaris code; no other game code or art was copied.

## Source and outputs

World JSON + asset registry -> WorldValidator -> exact procedural collision triangles and triangle-matched TerrainSampler -> TacticalExposureReview -> JSON metrics and an SVG overlay.

Run from repository root with .NET 8:

    dotnet run --project Tools/WorldTool -- review-tactical Review/latest/tactical

Outputs:
- tactical-exposure.json — source fingerprint, explicit thresholds, bounded options, sampled standing/crouch openness and district aggregations.
- tactical-exposure.svg — heat markers over the current authored world schematic.

The default sample spacing is 64m. A 1024m square world has at most 256 candidate locations. Lake and building-footprint samples are omitted; samples are not player spawns. From each remaining site, 16 horizontal bearings are tested at 1.6m standing and 1.0m crouching eye height with at most 96m range. The source BVH treats static collision triangles as double-sided cover. Terrain is sampled at the same triangle-interpolated heights used to compile the mesh.

A warning flag indicates >=75% standing bearings open, >=60% crouched bearings open and <=12.5% standing bearings encountering a static blocker within 20m. These are **Aaris authoring heuristics, not Free Fire/PUBG internal thresholds**. The analyzer does not put new objects into the world or rewrite object IDs/revisions.

## Guarantees and limitations

The report is deterministic for unchanged sources, stores a world-source fingerprint and rejects non-finite settings, invalid data or sample/ray budgets before creating any output. Regression tests cover a literal wall triangle vs open space, finite world bounds, repeatability/source immutability and work-budget refusal.

This is a sparse authoring review, **not** a verified gameplay heatmap: it omits shrubs/canopy visibility, moving opponents, destructible objects, dynamic lighting, traversal affordances, loot balancing, real player line of sight and peer-to-peer/server networking. An empty district sample count must not be interpreted as zero exposure. Engine-only performance and visual correctness are unverified until Unity editor and Android phone profiling. Manual playtesting and human review are needed before accepting actual placements.

Source CI executes only .NET C# tool checks and offline visual review. It does not build APK/AAB or invoke Unity.

## Public inspiration (design only)

- [Garena: Bermuda safer routes and covers](https://ff.garena.com/en/article/1170/)
- [Garena: clear Bermuda minimap](https://ff.garena.com/en/article/1385/)
- [PUBG: world/tactical-design roadmap](https://www.pubg.com/en/news/9855)
- [Unity: URP graphics profiling](https://docs.unity.com/en-us/engine/6000.3/manual/analysis/graphics-performance-profiling/in-urp)
