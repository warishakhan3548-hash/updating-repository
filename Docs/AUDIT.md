# Gameplay and collision audit / world revision 3

The upgrade uses public engineering ideas: bounded work/ownership, explicit query assumptions, spatial acceleration, geometry-derived review and measured before/after changes. It does not reproduce proprietary game-company internals or certify commercial quality.

## Confirmed source issues and changes

| Issue | Resulting change | Acceptance evidence |
| --- | --- | --- |
| Nearby cover distance was treated as the only tactical check | Build a bounded median BVH over terrain and original LOD0 collision triangles; trace standing-height routes in 24 directions | 250 independent brute-force oracle rays plus range/backface/tie/budget tests; offline world report |
| Large contiguous sampled exposure on three routes | Add six validated natural boulders, preserving every prior object transform/ID | Full world/sandbox placement validation and before/after visibility report |
| Roof collision was an outward-facing sheet, allowing underside query misses | Close each roof panel's collision volume with an underside and edges, keeping its visible roof triangles intact | Source triangle ray tests for every building archetype; native MeshCollider regression pending |
| Sphere-sweep normals can represent rounded edges rather than the actual face | Confirm the collider face with a short ray before classifying a walkable slope | New native steep-ramp test pending |
| Boolean jump/reload queues could replay old input after a stall | Timestamped one-shot pulses expire on a wall-clock deadline | Expiration/one-consumption/cancellation tests |
| A missing touch-end event could retain a held role while other fingers remained active | Prune owners against current live finger IDs; clear cancelled edge commands | Lost-owner regression; actual hardware acceptance pending |
| Sphere sweeps do not detect an initially overlapping camera volume | Check initial/final volumes, use bounded distance refinement and native-body anchor fallbacks | Three new native camera tests pending |
| A camera aim point behind the muzzle could create a backward ray | Reject the backward shot; block firing while no safe camera view exists | New native shot regression pending |
| Props that left the world could keep falling indefinitely | Restore out-of-bounds/nonfinite props to their bounded source positions | Engine acceptance pending; no per-frame object spawning |
| Global session settings were restored only on destruction | Release/restore physics and synthetic-mouse policy when disabled as well | Source lifecycle audit; Unity lifecycle acceptance pending |

## Accepted map change

The source moved from r2 to r3. All 375 existing object IDs and transforms are identical; six `ROCK_TACTICAL_*` placements were appended. The world now has 381 placements: 55 buildings, four towers, 210 trees, 88 rocks and 24 cover props. No extra houses/forests were scattered.

| Route | Longest flagged run before | After |
| --- | ---: | ---: |
| Courts–Foundry | 170.6 m | 78.0 m |
| Depot–Ridge | 215.0 m | 71.7 m |
| Willow–Foundry | 140.1 m | 75.6 m |

These numbers describe our fixed sampling heuristic, **not actual safe traversal distance, proven balance or a percentage comparison with PUBG/Free Fire**. A flag means at least 75% of sampled rays were unobstructed while at most 12.5% hit static collision within 20 m. Render concealment, tree canopy, player motion, server lag, weapon penetration and target distribution are not represented. The complete comparison and current fingerprinted review are in `Docs/Review/`.

`refine-cover request.json` writes a proposal only, with a revision guard, at most eight pairs, validated placement/density/sandbox spawns and an accepted visibility improvement for each pair. It stops if constraints cannot be satisfied; there is no forced overlap, endless scatter or automatic source overwrite. The reviewed proposal was explicitly promoted to the current source during this upgrade.

## Review commands

```bash
dotnet run --project Tools/WorldTool -- self-test
dotnet run --project Tools/WorldTool -- validate
dotnet run --project Tools/WorldTool -- validate-sandbox
dotnet run --project Tools/WorldTool -- review-visibility
dotnet run --project Tools/WorldTool -- refine-cover Tools/Commands/cover-refine-example.json
```

The last command is a dry proposal against the current revision. A changed world requires a fresh request. Visibility refuses external prefab overrides instead of pretending their collision is known. Work is bounded by triangle/sample/ray limits. The BVH is an offline diagnostic tool, not Unity physics, GPU occlusion culling or a runtime server acceleration structure.

## Primary references

- [PBRT authors: Bounding Volume Hierarchies](https://pbr-book.org/4ed/Primitives_and_Intersection_Acceleration/Bounding_Volume_Hierarchies): bounded hierarchies skip irrelevant triangle groups. Aaris uses its own median-split implementation, not PBRT's full renderer/SAH implementation.
- [Unity SphereCast](https://docs.unity3d.com/6000.3/Documentation/ScriptReference/Physics.SphereCast.html): initial overlaps and returned surface normals require care.
- [Unity backface query policy](https://docs.unity3d.com/6000.3/Documentation/ScriptReference/Physics-queriesHitBackfaces.html): query direction/winding matters. Closed roof collision avoids relying on a project-wide backface toggle.

102 .NET tests passed; native Unity test coverage is now 21 authored cases, still pending a licensed runner. Native movement, collision, camera and input hardware/FPS acceptance must be run before shipping. No APK/AAB was compiled.
