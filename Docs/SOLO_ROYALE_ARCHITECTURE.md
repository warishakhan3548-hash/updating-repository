# Aaris Highlands — single-phone battle royale architecture and upgrade gates

## Baseline / legal boundary
The original Unity 6.3 + URP world JSON is the sole editable world authority. No commercial Free Fire, PUBG or BGMI map, characters, assets or closed-source code are copied. Do not replace the core engine with an old sample project.

## Verified integration skeleton
`world.json` + `assets.json` + `sandbox.json` -> `SandboxValidator` and `BotSpawnPlanner` -> `UnityWorldCompiler` -> `PhysicsSandboxCompiler` -> Unity authored scene -> `SandboxSession` + `LocalBotDirector` + `PhysicsWeapon` + `SandboxHud`.

- Inputs and movement: native Rigidbody player + existing multi-touch ownership.
- Shot impact: `PhysicsWeapon.Trace` -> `HitRegion` -> `Damageable`.
- Enemy AI: centralized fixed-tick director; nearest 12 are updated at full rate, distant enemies at bounded low frequency. Bots use no 100 extra simulated Rigidbodies.
- Winner: living AI enemies fall to zero. Defeat: user health falls to zero. Reset restores match objects and controls.
- Live gameplay currently has **basic LOS/collision probes**, not NavMesh pathfinding or player-quality animated bot rigs.

## Source-derived gameplay comparisons
- Free Fire MAX: quick close-range engagements, short-match control responsiveness, readable damage and combat feedback. See https://ff.garena.com/en
- PUBG MOBILE: encounter distance, terrain, survival loot and shrinking zones. See https://www.lightspeed-studios.com/gamedetail/pubg-mobile.html
- Unity Technologies FPSSample: shooter architecture reference; **Unity 2018/HDRP sample is not a compatible Unity 6/URP drop-in.** https://github.com/Unity-Technologies/FPSSample
- Unity AI Navigation: modern NavMeshSurface/off-mesh link pathfinding when integrated in a subsequent PR. https://docs.unity3d.com/Manual/com.unity.ai.navigation.html
- Simulation LOD reference: https://github.com/matbcontrol/massive-objects-showcase — conceptual guidance only.
- URP terrain chunking reference: https://github.com/GuglielmoMazzesiDaniele/ProceduralTerrain — conceptual guidance only.
- Unity mobile GPU profiling: https://docs.unity.com/en-us/engine/6000.3/manual/analysis/graphics-performance-profiling/in-urp

## Next independent feature gates (do not silently merge unrelated draft PRs)
1. **Actual NavMesh navigation**, edited/baked per cell in Unity; door/stair traversal, route recovery, no through-wall targets, bot-vs-bot combat. Must not frame-hitch when 100 bots ask for paths.
2. **Art quality:** original authored physically based character rig, locomotion animation, inverse kinematics, proper weapon/impact audio, differentiated enemy skins; distant actor LOD and shared materials.
3. **Rendering:** careful merge review of existing foliage-wind, day/dusk, terrain/water and streaming draft PR branches; measure SRP Batcher, LOD popping, lightmaps/probes and frame pacing. Do not imply they're merged.
4. **Combat/UX:** airdrop, dropship/landing, cover placement, gear/inventory, mobile inventory panels, safe zone awareness, match results, aim-assist fairness and tutorial.
5. **Map design:** sightline audit, bot heatmaps, safe-landmark encounters, indoor traversal, biome ground clutter with deterministic GPU wind.
6. **Performance:** capture actual CPU main thread, physics, render thread, GPU, draw calls, memory, GC spikes and thermal throttling on low/mid/high Android phones. Design for stable 30 FPS minimum tier and optional 60 FPS quality tier; no FPS promise before hardware measurement.

## No APK yet
Run:
```bash
dotnet run --project Tools/WorldTool -- self-test
dotnet run --project Tools/WorldTool -- validate
dotnet run --project Tools/WorldTool -- validate-sandbox
```
Then import with licensed Unity **6000.3.26f1**, compile Physics Sandbox (No APK), run Editor tests/PlayMode at bot counts 50 and 100, and profile on Android. Generate release APK only at an explicit milestone.
