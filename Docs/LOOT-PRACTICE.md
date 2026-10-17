# Original district loot milestone (local practice only)

## Why this change

The six authored Highlands districts are currently geometry destinations rather than
places with a repeatable resupply incentive. This milestone introduces a limited
ammo/medical pickup loop using the existing validated world and native sandbox.
The gameplay idea is informed by public [Free Fire war chest design](https://ff.garena.com/en/article/351)
and [PUBG's land-loot-survive overview](https://www.pubg.com/en/game-info/overview).
No proprietary assets, shaders, code or map locations are reused.

## Dependency and visual/state maps

```
world.json ──────> WorldValidator ───┐
 assets.json ─────> WorldCompiler ───┤
 sandbox.json ────> SandboxValidator ┤
                                     v
                         LootPlanner.Generate(world, assets, sandbox)
                                     |
                          safe, stable LootDrop[] (local)
                                     |
                  PhysicsSandboxCompiler (EditMode generation only)
                                     |
                 prefab-free crystal + LocalLootPickup components
                                     |
                          SandboxSession.FixedUpdate
                                     |
                spatial radius + WORLD-only obstruction ray
                                     |
                    ┌────────────────┴────────────────┐
             WeaponState.TryAddReserve          PlayerHealth
                    |                                 |
                 SandboxHud                   SandboxHud
```

The player moves via SandboxInput -> PhysicsPawn -> Rigidbody. Every 0.2 seconds
the active sandbox session looks for visible crystals within the configured pickup
radius, refuses pickups behind a world collider, and consumes eligible items once.
Health at maximum capacity and ammo reserve at its cap do not consume rewards.
The same RESET control restores session health, weapon inventory and pickups.
Pickups have no Rigidbody, colliders, per-object Update loop or external prefab
dependency. They are generated only when the sandbox scene is compiled in Unity.
The cached minimap retains its existing behavior and does not reveal loot through walls.

## Invariants and design choices

- The world JSON remains authoritative: same 1,024 x 1,024 m terrain and permanent
  placement IDs. No world source revisions or source transforms are modified.
- An opt-in, separately versioned `sandbox.loot` section bounds total pickups (up to
  48), district count, placement spacing, rewards and collection radius.
- Candidate locations follow a deterministic seed-dependent ring around each
  canonical district. The generator checks world bounds, lake margins, slopes,
  conservative obstacle footprints, player/target/prop clearance and distance
  between accepted drops. If a district has no valid candidate, fewer items
  are returned rather than forcing unsafe placement.
- The local player gets one reachable candidate near spawn if a safe point
  exists; acceptance is not guaranteed if the authored map becomes obstructed.
- The planner runs during editor compilation, not every gameplay frame.
  Core tests exercise reproducibility after source array permutations, limits,
  terrain/water/collision constraints and ammo accounting.
- The generated primitive crystal and colors are temporary, project-owned
  development graphics. This does **not** create a photorealistic character,
  inventory UI, weapon attachment system, live network replication, safe multiplayer
  item authority, streamed cells or production art.
- Real-time occlusion uses only the actual Unity World physics layer and
  is deliberately conservative. It is not general navmesh reachability:
  an item can be individually legal yet hard to reach from a particular route.

## Acceptance gates

1. GitHub .NET 8 source CI must compile core source with the repository's
   C#-9/.NET Standard-2.1 compatibility check, pass all regression tests,
   validate world/sandbox JSON and produce schematics.
2. In Unity 6000.3.26f1/URP 17.3, invoke **Aaris > Gameplay > Compile Physics
   Sandbox (No APK)** and run EditMode tests. Inspect serialized loot components,
   mesh/no-collider creation and source-to-scene placement consistency.
3. In Play Mode, move to a crystal and verify ammunition pickup, medical
   pickup after losing health, obstruction rejection, single collection and RESET.
   Confirm all existing controls, aiming, safe-zone damage, minimap and camera
   still behave correctly. Confirm visual clarity on target Android phones.
4. Only claim performance after on-device profiling of frame time, memory,
   allocations, UI readability and thermals. No Android APK/AAB build is run
   or triggered by source-only changes.

This branch stacks on PR #680's tactical-sandbox branch, and **must not**
be merged straight into `main` before the parent changes are reviewed.
Independent shader/foliage branch #679 is deliberately not silently integrated.
