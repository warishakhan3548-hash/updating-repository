# Local solo battle match — draft, source-only

## Scope and status
This branch implements a **prototype** for 50 local battle opponents (configurable to
100) in the existing Unity 6.3 / URP physics sandbox. It does **not** create a
Free Fire/PUBG clone, final character art, a shipped Android game, a networked
multiplayer engine, or production-capable NavMesh AI. All opponent AI, bullets,
physics and match state are computed locally on one phone with **no servers**.
The world authoring source, 381 stable placements and world revision are unchanged.
This draft is stacked on the dependency-safe streaming-policy branch (PR #685),
which itself depends on the loot and tactical-presentation drafts.

## Dependency and state graph
`sandbox.json.bots` -> `SandboxValidator` -> `BotSpawnPlanner.Generate` ->
`PhysicsSandboxCompiler` -> generated `LocalBotAgent[]` and
`LocalBotDirector` -> Unity fixed-step scheduler ->
`CharacterController.Move` and collision/LOS ->
`SandboxSession.DamagePlayer` -> winner/loss in existing HUD.

Player bullet: `PhysicsWeapon.Trace` -> `HitRegion` ->
`Damageable.Apply` -> exact player elimination credit.
Bot death by closing zone is not credited to player.
The same RESET UI button restores health, bots, zone, loot and shot counters.
A disabled bots section retains the original target-practice behaviour.

## Safety and computational policy
- 1-100 stable bot IDs, seeded Halton spatial sampling, terrain slope/shoreline
  exclusion, footprint collision, actor clearance and current initial safe zone.
  Insufficient safe placements fail before the generated scene is saved.
- One `LocalBotDirector`, with a strict decision cap
  (`decisionsPerStep=4` at 50 Hz). No independent 50-100 `Update()` loops.
- Distant controllers move at 5 Hz, close combat stays at fixed-step frequency.
  This is a scheduling design, **not** a measured 100-bot frame-rate result.
- Bots are kinematic CharacterControllers; the player and up to 6 props remain
  native Rigidbody actors. Bot colliders use the preexisting `AarisTarget`
  layer and `HitRegion` damage dispatch.
- No target is allowed to fire through authored world or dynamic props. The
  simple local obstacle-avoidance approach can still get stuck; proper baked
  NavMesh routing and cover tactics are explicitly future acceptance work.
- Zone damage can eliminate bots; a surviving player wins only when all living
  bots are eliminated. Player death ends the match without auto-restarting.
- Bot materials, capsule bodies and helmets are development placeholders.

## QA gates (do not skip)
1. Run `dotnet run --project Tools/WorldTool -- self-test` and
   `dotnet run --project Tools/WorldTool -- validate-sandbox`.
   Expected source bot cases: 50/100 capacity, spawn determinism, object-order
   invariance, tuning bounds, victory, line-of-sight and fire cooldown.
2. On a licensed Unity 6000.3.26f1 editor: **import and compile** all assemblies,
   run EditMode tests, compile the gameplay scene via
   `Aaris/Gameplay/Compile Physics Sandbox (No APK)`.
3. In Unity Play mode: verify bots not inside meshes/water; character-collision,
   player head/body hits, clear/occluded bot shots, zone attrition, 50/100 target
   resets, 0 HP loss, HUD and no victory before final elimination.
4. On representative low/mid/high Android devices: use Unity Profiler/Frame
   Debugger to capture 1% low fps, CPU/GPU p95 frame time, memory, thermal
   throttling, 15-minute 50/100-bot traversal and battery.
   Optimize or reduce active bot count based on **measured** performance.
5. Before final visual quality: upgrade to licensed original rigged humanoid
   art, terrain/vegetation PBR, baked LOD/HLOD, material variants and accurate
   hitboxes; test graphics quality tiers and actual animation/physics.
6. Do not merge stacked branches until prerequisites, Unity compile and device
   tests pass. Do not run an APK/AAB build unless explicitly requested.

## Public reference principles (no imported proprietary game code)
- Unity 6 URP rendering/culling: https://docs.unity.cn/6000.0/Documentation/Manual/urp/reduce-rendering-work-on-cpu.html
- Unity navigation: https://docs.unity.com/en-us/engine/6000.0/script-reference/unityengine/ai/navmeshagent
- DOTS sample concepts (not directly imported): https://github.com/Unity-Technologies/EntityComponentSystemSamples
- PUBG Mobile public Livik game-mode design: https://www.pubgmobile.com/en/event/Official-Livik-Map/

No external source, textures, gameplay implementations or commercial assets were
copied into this project.
