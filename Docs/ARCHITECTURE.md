# World authoring v2

The tactical presentation dependency/state map is documented in
[`TACTICAL-UPGRADE.md`](TACTICAL-UPGRADE.md). It connects the existing world source,
local simulation and read-only minimap without introducing a second map source.

The project uses public large-world engineering principles: stable identities, spatial partitioning, repeatable compilation and explicit performance budgets. This is our implementation; no claim is made to reproduce proprietary PUBG/Free Fire internals.

## Source and compiled outputs

| Layer | Editable source / code | Responsibility |
| --- | --- | --- |
| World data | `Assets/GameData/World/world.json` | Grid, seed, terrain, roads, districts, markers and object transforms |
| Art registry | `Assets/GameData/World/assets.json` | Stable asset IDs, dimensions, placement limits, provenance and estimates |
| Shared C# core | `Assets/Aaris/World/Core/` | Terrain, geometry, validation, cell compilation and streaming selection planning |
| Command tool | `Tools/WorldTool/` | Strict JSON input, safe moves, schematic review and regression tests |
| Unity authoring | `Assets/Aaris/World/Editor/` | Real engine mesh/prefab construction, URP setup and PNG export |
| Generated data | `Assets/Generated/`, `Review/` | Disposable outputs, never master source |

Unity scenes are compiled from data. The compiler creates **one fully loaded review scene**, with a group per cell. It does not yet create a shipping streamed world. Avoid maintaining two competing world sources.

## Coordinate and identity contract

- Metres; +Y up; +Z north; +X east; yaw follows Unity's clockwise rotation around +Y.
- Object asset roots use a centred X/Z pivot at ground Y=0. Scale is uniform.
- Transform Y is resolved from the mesh-compatible terrain sampler plus an explicit ground offset.
- IDs remain stable when objects move; do not encode current cell coordinates into object IDs.
- A cell owner is calculated from the object's anchor. Every cell touched by its rotated footprint's AABB also contains a conservative reference. Boundary references can include an extra cell by design.
- A future runtime loader must resolve owner dependencies and instantiate each object only once. Loading cell references independently would duplicate structures and is prohibited.

## Deterministic terrain and compilation

Terrain uses a versioned integer hash, smoothed noise octaves, authored flattening pads and an explicit seed. Unity and the .NET tool compile the same C# sampler. Lattice vertices align globally across cell boundaries; the CPU ground sampler interpolates the same triangles as the Unity mesh, rather than a visually different noise surface. Vertex normals sample global gradients to avoid seam lighting discontinuities.

Object order and asset registry order do not change the compiled plan. Cell order and placements sort canonically. Pad order is intentionally meaningful if pads overlap. Keep resolved plans and source hashes together when reviewing a change. The seed and source produce repeatable authoring output; this is **not** a deterministic multiplayer physics implementation or a guarantee of bitwise floating-point equality across every platform.

## Placement and editing

Validation rejects malformed sections, duplicate IDs, unknown references, non-finite coordinates, invalid dimensions, path traversal, rotated out-of-bounds footprints, intersecting structures, road clearance violations and excessive terrain slope/relief. The overlap broad phase uses cell buckets; narrow phase uses the separating-axis test for oriented footprints. Inter-object spacing is half of each asset's clearance added to its footprint, so equal clearances produce the requested gap. Road clearance measures distance to the entire footprint, including crossing road segments and endpoints.

Foundation checks probe the footprint on a grid no coarser than terrain spacing, plus corners and centre. They are conservative authoring checks, not a substitute for collision/playability tests of final models. The road preview follows existing terrain and merges coplanar junctions into one surface; cut/fill and final road collision remain future work. Full terrain collision remains underneath it.

The move command reads a revision, resolves the object and optional marker, clones the world, applies the edit, validates the whole result and only then writes it atomically. A dry run does not write. Use one working-copy writer at a time; atomic replacement prevents partial files, not a distributed multi-writer transaction. Git's non-forced branch update is the final lost-update protection.

Markers in v1 are authored IDs in the JSON. Runtime marker capture, fly camera and an in-game inspector are not implemented yet. A future video command must identify an object and an unambiguous marker/target; videos alone do not always reveal precise world coordinates.

## Budgets and streaming boundary

Static placement/terrain estimates count geometry, material slots, colliders and shadow casters in every referenced cell. Texture estimates count each asset ID once per cell. They exclude dynamic actors, road geometry, UI, effects and allocator/renderer overhead. Different asset IDs may share textures; estimates are intentionally conservative. They are neither draw calls nor measured memory/GPU performance. Real renderers and final prefabs need target-phone profiling.

The C# streaming planner selects cells by distance to their **bounds**, with a larger unload radius to avoid repeated load/unload at cell boundaries. It fails explicitly if a resident-cell cap would be exceeded; it never hides missing nearby collision by dropping cells. This is a tested selection policy, not an async loader. Addressables loading/cancellation, dependencies, HLOD baking, terrain collider lifecycle, pooling and per-frame work limits are later milestones, after the first real Unity and device measurements. No Addressables package is added until its loader is implemented.

## Build and review policy

1. Source checks run on relevant pushes/PRs. They compile only the .NET authoring tool, run its tests, validate data and produce a schematic review.
2. Unity scene compilation/EditMode checks and graphics PNG export run only when explicitly invoked on a licensed editor runner. A graphics device is needed for PNGs; `-nographics` cannot render them.
3. Android release compilation is absent. Add a manual-only pipeline when requested, with signing and target-device requirements. Do not attach Android compilation to world edits.

The first next engineering gate is a real Unity import/compile + EditMode run, followed by actual 3D screenshots. Before calling any milestone production-ready, add a representative target-phone performance and traversal test. GitHub is source control/CI; it does not eliminate Unity activation or supply paid infrastructure automatically.

## Public technical references

- [Pinned Unity release: 6000.3.26f1](https://unity.com/releases/editor/whats-new/6000.3.26f1)
- [Unity editor command-line arguments](https://docs.unity3d.com/6000.3/Documentation/Manual/EditorCommandLineArguments.html)
- [URP 17.3 API](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@17.3/manual/)
- [URP SingleCameraRequest](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@17.3/api/UnityEngine.Rendering.Universal.UniversalRenderPipeline.SingleCameraRequest.html)
- [Epic World Partition overview](https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition-in-unreal-engine)

These inform engine integration and partitioning choices; they do not certify our project's performance or readiness.

## Revision 2 additions

Schema v2 adds explicit hills, lake/shore terrain, biomes, source road curves, reserved routes and bounded district density. V1 remains readable. All original placement IDs survive the one-time migration.

Engine-independent C# generators create architecture, trees, rocks and props. Unity templates share these meshes/materials across placements and expose three LODs. Root collision persists through visual LOD switches; canopy geometry is not included in tree collision. Native terrain uses smooth biome/slope/shore tints and a URP terrain shader. Material albedo and normal data is generated deterministically and cached per used surface.

Roads use continuous mitered ribbons and planar polygon subtraction to remove coplanar intersection overlaps. Final road collision/cut-and-fill remains future work. Terrain, water, roads and procedural asset geometry are exported unchanged for Blender visual QA; external prefab overrides intentionally refuse offline export because they require Unity inspection.

Design checks enforce world/cell/district populations, assigned building footprints, biome tree counts, connected/redundant district links, reserved walking corridors, slope limits and sampled nearby-cover targets. Cover availability is a spatial heuristic, not a sight-line or combat safety guarantee. Footprint occupancy is conservatively estimated using all referenced object footprints; per-cell anchor counts and spatial references have different meanings.

Procedural geometry costs derive from generated meshes and configured texture resolution; final prefab costs still use registry estimates. Runtime device memory/frame time, dynamic actors, roads and effects require separate profiling. Current compilation still creates a fully loaded review scene, not an asynchronous streamed game. See `RESEARCH.md` for primary references and project-specific targets.

## Terrain-aware route proposals

`plan-route` runs bounded 8-neighbour A* with nonnegative distance/elevation costs, an admissible distance heuristic and deterministic priority ties. Continuous segment tests avoid conservative obstacle footprints and inflated lake masks; sampled terrain slopes constrain candidate edges and endpoint connectors. Diagonal side checks prevent blocked lattice corner cutting. A bounded shortcut pass rechecks safety and does not accept a higher sampled terrain cost. Endpoint coordinates remain exact.

Requests carry the current world revision; results carry a source fingerprint. Missing endpoints, blocked connectors, invalid costs, grid budgets, search budgets and unreachable destinations fail explicitly. Proposals never rewrite source. This is an outdoor authoring tool, not a runtime navigation system, globally optimal continuous road solver, vehicle handling guarantee or bridge/tunnel generator. It conservatively uses full registered object footprints, including tree canopies. Centreline slope sampling does not certify the entire width of a future road. A route must still satisfy design checks and engine traversal review before promotion.

## Local physics milestone

`Assets/GameData/World/sandbox.json` supplies separately revisioned simulation, movement, weapon and spawn settings. The existing world data/IDs are unchanged. `PhysicsSandboxCompiler` builds the world, keeps authored structures static and adds one native Rigidbody capsule plus a bounded prop set. Player input/timers are independent of Unity geometry; forces and scene-scoped collision queries run in the native runtime. The Unity tests distinguish solver behaviour from the .NET policy tests. See `GAMEPLAY.md` for lifecycle, layers, controls and acceptance limits.

## Revision 3 collision/visibility audit

Six natural cover placements were accepted using sampled static collision visibility, with all pre-existing object transforms preserved. A bounded median BVH is shared C# authoring code, not a runtime PhysX substitute. Closed roof collision panels preserve the visible geometry. Timestamped input pulses, touch-owner pruning, camera overlap/backward-shot guards and bounded prop recovery address failure paths in the local sandbox. See `AUDIT.md` for measured review values and the engine acceptance boundary.
