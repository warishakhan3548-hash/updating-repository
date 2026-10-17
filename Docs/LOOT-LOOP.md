# Aaris Highlands — deterministic district loot (stacked draft)

This upgrade sits on `feature/tactical-presentation-upgrade` (PR #680), not main. It uses the existing Unity sandbox and the authoritative `world.json` without adding a second world data source or mutating permanent placements. The 1,024 m map, six authored districts and 381 placement identities remain unchanged.

## Runtime/state trace

World/asset source + sandbox source → validated map → `LootPlanner.Build` (three original practice pickups per district) → Unity editor preflight → physics sandbox compiler generates visual-only pickup objects → `SandboxSession.FixedUpdate` checks close approach and native world-collider line of sight → bounded healing or `WeaponState.GrantReserve` → pickup disappears → session reset respawns pickups. World collision and camera/weapon trace are unchanged.

Each district receives one 35-HP healing supply and two 30-round ammo supplies. The policy is deterministic across launches and insensitive to the order of source objects. It samples candidate positions in the landmark's radius, checks water, map bounds, incline, authored object footprints, spawn proximity, other pickups, and the initial practice-zone boundary. If no safe layout exists, it refuses to destroy/recompile the previous generated scene. Pickups have no colliders, extra rigidbodies or runtime world-file writes. Collecting through a wall is blocked by a physics raycast. Full health or full reserve ammunition cannot consume pickups.

This is a deliberately small, original **single-player practice** loot loop. It does not implement backpack UI, weapon attachments, loot tables, an item economy, physical dropped items, server-authoritative inventory, online anti-cheat, or production-quality models. The cubes and spheres are temporary PBR-coloured markers, not final art. No Free Fire/PUBG source/assets/maps have been copied.

## Verification and gates

The new .NET tests cover deterministic per-district coverage, permanent-seed variability, object-order independence, water exclusion, safe failure and ammunition conservation/cap/reset. Run:

```sh
dotnet run --project Tools/WorldTool -- self-test
dotnet run --project Tools/WorldTool -- validate
dotnet run --project Tools/WorldTool -- validate-sandbox
```

Native Unity 6000.3.26f1 import, Editor/PlayMode physics and GPU frame timing **must still be tested** before calling this game feature accepted. On a target Android phone confirm pickup radii near ramps/walls/roofs, LOS around crates and geometry, reset/resupply repeatability, health recovery only after damage and touch controls. This draft has no Android build trigger, no multiplayer network or final AAA textures.

Research: official PUBG gameplay overview (landing, looting, rotations and shrinking zone), Garena Free Fire Gloo Maker notes (combat resource loops), Unity URP mobile profiling docs and Unity Addressables samples are design references only; none is copied into this repo.
