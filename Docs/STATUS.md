# World r2 / local physics sandbox r1 status

Implemented: six-district layout; bounded settlement/vegetation density; hill/lake/biome authoring; reserved walking corridors; redundant district connections; sampled cover proximity and slope checks; original procedural architecture/trees/rocks/props; shared templates; three LODs; albedo/normal material generation; URP scene authoring; exact-source offline geometry export; bounded terrain-weighted route proposals with exact endpoints and safe shortcut checks.

Current world: 1024 × 1024 m, 64 cells, 375 placements: **55 buildings, 4 towers, 210 trees, 82 boulders and 24 props**. All 72 original placement IDs remain present. Source schema is v2; v1 remains readable.

## Checks performed

- **92 C# regression/invariant tests passed** using the actual .NET 8 SDK compiler/runtime: v1 behaviour plus density, connectivity, water restrictions, mesh bounds/indices/degeneracy, LOD counts, doorways, trunk-only tree collision, materials, non-overlapping road junctions and terrain-aware routing (obstacle/water detours, budgets, invalid requests, stable results), plus sandbox placement/budgets, jump timing, ammunition/cadence/reload and independent touch ownership.
- Core sources also compile against .NET Standard 2.1 with C# 9, the intended Unity-compatible API/language boundary.
- The r2 source validates and the marker move dry run passes. Art catalog triangle counts match generated geometry; cell budgets derive procedural geometry costs directly and account for the configured texture resolution.
- Blender 4.2 CPU Cycles rendered exact C# geometry into overview, Courts and Ridge views. Visual QA found stacked road-strip artifacts; mitered ribbons and polygon subtraction fixed them before the final images were produced.
- The schematic, data fingerprint and metrics come from checked-in JSON. Offline review images and provenance are saved under `Docs/Review/`; large geometry exports remain disposable.

GitHub's `World source checks (no APK)` workflow compiles the ordinary .NET project, runs all tests, validates source and generates a small review bundle. Its result on the published commit is authoritative for CI status.

## Unity/device checks pending

Actual Unity import, URP shader compilation, **15 EditMode integration tests**, editor PNG rendering and target-phone profiling have not run here. Compilation/tests require a licensed Unity editor; PNG rendering additionally needs a graphics-capable runner. Blender uses different lighting/rendering; its images do not validate Unity behaviour, mobile memory, frame rate or battery usage.

Native Rigidbody movement, touch controls, camera obstruction, local hitscan shooting/targets, friction materials and bounded physical props are now implemented as source in a separate sandbox scene compiler. See `GAMEPLAY.md` for the exact boundary and remaining work. These have not been executed in Unity here.

No APK/AAB was compiled and no Unity Cloud service was provisioned. This is an authoring review scene. Runtime cell loading/cancellation, Addressables, HLOD, final prefab/texture compression, swimming, final road collision/cut-and-fill, native player/combat acceptance, animated characters, full weapon systems, bots and multiplayer remain later work. Development art does not establish commercial readiness or superiority to another game's final graphics.
