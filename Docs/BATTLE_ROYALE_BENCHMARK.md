# Aaris Highlands — official Battle Royale benchmark and integration map

## Public references (feature inspiration, not source-code access)

| Reference | Verified public mechanic | Original Aaris adaptation |
| --- | --- | --- |
| Free Fire Solara (Garena, 2025) | 1400 x 1400 m, connected city/biome regions, world slide transit, weather/day-dusk effects | Distinct districts, authored fast transport, controlled local atmosphere; current 1024 m world remains authoritative |
| Free Fire Bermuda / patch notes | Loot hotspots, safe-zone pacing, windows and combat collision updates | Data-driven loot, sampled combat sightlines and doorway tests |
| PUBG MOBILE Livik | 2 x 2 km small match, airdrops, upgraded urban zones, transport, zipline, supply shop | Short solo round, local loot/airdrop objectives and traversal |
| Unity URP documentation | SRP Batcher, reduced shadow cascades, LOD, mobile renderer memory optimization | Measure main/render/GPU frame pacing, then adaptive quality |

Garena: https://ff.garena.com/en/article/1482/
Garena map patch: https://ff.garena.com/en/article/1673
PUBG: https://www.pubgmobile.com/en/event/Official-Livik-Map/
Unity: https://docs.unity3d.com/6000.0/Manual/urp/configure-for-better-performance.html

**IP / licensing boundary:** Never copy proprietary Free Fire, PUBG/BGMI meshes, maps, textures, graphics, AI code or UI art. Open source is usable only after checking its license, Unity version/renderer compatibility and maintenance. For example, Unity AI Navigation provides the supported NavMesh tooling, but it is not a drop-in replacement for the existing terrain compiler. Source examples and performance techniques should be adapted, not blindly imported.

## Dual architectural map

Data path:

`world.json + assets.json + sandbox.json`
-> `WorldValidator/SandboxValidator`
-> `BotSpawnPlanner.Plan` (author time, collision-aware)
-> `UnityWorldCompiler.Compile` (terrain meshes, URP, authored placement)
-> `PhysicsSandboxCompiler.Compile` (bots/props/player/targets)
-> Unity physics scene -> `SandboxBot` (distance-tiered local decisions)
-> `SandboxSession` (zone, health, winner)
-> `SandboxHud` (display).

Input/UX path:

Touch/keyboard -> `SandboxInput` -> `PhysicsPawn` movement / `PhysicsWeapon.Trace` -> `HitRegion` -> `Damageable` -> match state -> HUD.
Bot decision -> scene LOS, ground, collision probes -> kinematic movement or player health -> match state -> HUD.

**Surgical integration points**: Source bot bounds live in `Core/SandboxSpec.cs`; spawn selection lives in `Core/BotSpawnPlanner.cs`; actor creation lives in `Editor/PhysicsSandboxCompiler.cs`; movement/attack lives in `Runtime/SandboxBot.cs`; health, outcomes and reset live in `Runtime/SandboxSession.cs`. World JSON, permanent IDs, shaders and native player motion are untouched.

## Remaining mandatory AAA-inspired milestones

1. Consolidate overlapping draft PRs before merge. There are independent bot branches #689 and #690, loot branches #681/#683, graphics/vegetation branches #679/#684/#686/#687, and cell-streaming #685. Their dependencies and overlapping source files must be reconciled, not automatically cherry-picked all at once.
2. Replace approximate obstacle probes with genuinely traversable baked/navigation-cell paths, intelligent cover, door/stair links and stuck recovery. Use a central bounded scheduler before accepting 100 agents.
3. Implement physically consistent weapon aim, ammo/reload, difficulty, opponent-vs-opponent engagements, credible hit animation and loot/inventory.
4. Create original human animation rigs and commercially usable visual assets: PBR terrain, believable vegetation, wind, sky/weather, SSAO only where budgets permit, material/mesh LOD and rigged NPC avatars.
5. Ship async world streaming only when ownership, collider activation and memory budgets are tested on device. Procedural geometry screenshots are not equivalent to runtime Android frame-time proof.
6. Measure 30fps (33.3ms frame budget), optional 60fps (16.7ms), CPU, render thread, GPU, memory, thermal and 1% lows on several real Android GPUs. Drop costs and adjust tiers based on measurements.

## Verified versus pending

The GitHub .NET 8 source workflow validates core policies and world source. It does not compile Unity runtime classes, run PhysX, animate models, render on a GPU or measure Android performance. Keep the bot change in draft until licensed Unity 6000.3.26f1 compile, integration tests and hands-on mobile testing pass. No APK/AAB was created.
