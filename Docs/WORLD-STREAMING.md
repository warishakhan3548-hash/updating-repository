# Aaris Highlands — dependency-safe cell streaming policy (no APK)

## Goal and current boundary

UnityWorldCompiler currently constructs one fully loaded review/sandbox scene. The new
`StreamingTransitionPlanner` computes safe **proposed transitions only** from the
existing single source of truth (`world.json` + `WorldCompiler.Compile`).
It does **not** stream scenes, unload meshes, enable Addressables, modify world
placements, toggle colliders, or change the current rendering.

## Source-to-runtime dependency graph

`world.json` + `assets.json` → validated `WorldPlan` → `StreamingPlanner.Desired`
(hysteresis and terrain bounds) → `StreamingTransitionPlanner.Plan`
(owner dependencies, bounded capacity, priorities) → future Unity loader.

A world object is authored and instantiated **once** by its owner cell.
A cell's `references` identify overlapping objects, not extra instances.
For every nearby cell, the planner includes the owner cell of each referenced
object, without recursively walking extra references from an owner cell.
If dependency expansion exceeds `maxResidentCells`, planning **fails closed**.
It never drops the player-adjacent terrain, a required object or collision.

## Ordered transition contract for a future runtime loader

1. Verify source revision, finite and in-world player coordinates, cell manifest and resident set.
2. Plan `requiredCells`, `loadOrder`, `releaseOrder`, and unique `referencedObjects`.
3. Instantiate missing owner dependencies before the cells referencing them; load nearby
   terrain before equally optional distant cells. Equal-distance cells favor up to 64m
   of forward travel (0.35s lookahead); all priorities are deterministic.
4. **Commit atomically** only after required scene/physics content has finished loading;
   do not release old colliders while the player is crossing a seam.
5. Release unused cells farthest first. Real loader must handle cancellation, failures,
   pooled objects, async main-thread budgets and memory high-water marks.
   `maxResidentCells` limits steady-state required cells, **not** transient memory
   from simultaneous inflight load/release operations.

## Verification and constraints

- Five pure .NET regression cases: owner-before-reference, dependency capacity,
  direction-sensitive order, deterministic/deduplicated release and fail-closed invalid inputs.
- Existing world placements, 64-cell source, procedural art, URP, rendering, touch,
  combat and all previous streaming `Desired` semantics are unchanged.
- No Unity import/PlayMode/device frame-time test is claimed; source CI validates
  only pure .NET C# until a licensed Unity Editor is run.
- Do not enable real streaming until camera visibility, terrain/road/water continuity,
  world-object overlap, safe-zone, projectile collision and phone traversal are tested.
- This is a foundation for future streaming, **not** an FPS boost by itself.

## Primary engineering references

- [Unity Megacity Metro](https://github.com/Unity-Technologies/megacity-metro)
  — large-world streaming, URP and server-authoritative multiplayer reference.
- [Unity Boat Attack](https://github.com/Unity-Technologies/BoatAttack)
  — mobile URP/LOD/Addressables environment techniques.
- [Unity GPU draw-call optimization](https://docs.unity.com/en-us/engine/6000.6/manual/analysis/graphics-performance-profiling/reduce-draw-calls/optimizing-draw-calls-choose-method)
  — evaluate SRP batching, GPU resident drawing and LOD on measured device profiles.
These are references; no proprietary game, sample textures, models or source files were copied.
