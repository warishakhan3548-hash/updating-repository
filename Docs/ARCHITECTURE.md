# World authoring v1

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

Unity scenes are compiled from data. The first compiler creates **one fully loaded review scene**, with a group per cell. It does not yet create a shipping streamed world. Avoid maintaining two competing world sources.

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

Foundation checks probe the footprint on a grid no coarser than terrain spacing, plus corners and centre. They are conservative authoring checks, not a substitute for collision/playability tests of final models. The road preview follows existing terrain and has no cut/fill or final junction solution yet. Full terrain collision remains underneath it.

The move command reads a revision, resolves the object and optional marker, clones the world, applies the edit, validates the whole result and only then writes it atomically. A dry run does not write. Use one working-copy writer at a time; atomic replacement prevents partial files, not a distributed multi-writer transaction. Git's non-forced branch update is the final lost-update protection.

Markers in v1 are authored IDs in the JSON. Runtime marker capture, fly camera and an in-game inspector are not implemented yet. A future video command must identify an object and an unambiguous marker/target; videos alone do not always reveal precise world coordinates.

## Budgets and streaming boundary

Static placement/terrain estimates count geometry, material slots, colliders and shadow casters in every referenced cell. Texture estimates count each asset ID once per cell. They exclude dynamic actors, road geometry, UI, effects and allocator/renderer overhead. Different asset IDs may share textures; estimates are intentionally conservative. They are neither draw calls nor measured memory/GPU performance. Real renderers and final prefabs need target-phone profiling.

The C# streaming planner selects cells by distance to their **bounds**, with a larger unload radius to avoid repeated load/unload at cell boundaries. It fails explicitly if a resident-cell cap would be exceeded; it never hides missing nearby collision by dropping cells. This is a tested selection policy, not an async loader. Addressables loading/cancellation, dependencies, LOD/HLOD baking, terrain collider lifecycle, pooling and per-frame work limits are later milestones, after the first real Unity and device measurements. No Addressables package is added until its loader is implemented.

## Build and review policy

1. Source checks run on relevant pushes/PRs. They compile only the .NET authoring tool, run its tests, validate data and produce a schematic review.
2. Unity scene compilation/EditMode checks and graphics PNG export run only when explicitly invoked on a licensed editor runner. A graphics device is needed for PNGs; `-nographics` cannot render them.
3. Android release compilation is absent from v1. Add a manual-only pipeline when requested, with signing and target-device requirements. Do not attach Android compilation to world edits.

The first next engineering gate is a real Unity import/compile + EditMode run, followed by actual 3D screenshots. Before calling any milestone production-ready, add a representative target-phone performance and traversal test. GitHub is source control/CI; it does not eliminate Unity activation or supply paid infrastructure automatically.

## Public technical references

- [Pinned Unity release: 6000.3.26f1](https://unity.com/releases/editor/whats-new/6000.3.26f1)
- [Unity editor command-line arguments](https://docs.unity3d.com/6000.3/Documentation/Manual/EditorCommandLineArguments.html)
- [URP 17.3 API](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@17.3/manual/)
- [URP SingleCameraRequest](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@17.3/api/UnityEngine.Rendering.Universal.UniversalRenderPipeline.SingleCameraRequest.html)
- [Epic World Partition overview](https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition-in-unreal-engine)

These inform engine integration and partitioning choices; they do not certify our project's performance or readiness.
