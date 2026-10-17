# Aaris Highlands: evidence-based visual upgrade

## Scope (17 October 2026)

This change retains the original Unity 6000.3 / URP 17.3 game, source world revision 3 and sandbox revision 2. It does not copy PUBG, BGMI or Free Fire assets or proprietary code; no player build or online service is triggered.

### Source-to-render dependency map

`world.json` + `assets.json` -> `WorldValidator` -> `WorldCompiler` -> `UnityWorldCompiler` -> `ProceduralArtBuilder` -> shared three-LOD prefabs/materials -> native URP camera.

`ProceduralArt.Create` emits `assetId_leaf` parts for oak/pine archetypes. `ArtPalette.Surfaces` labels them with `pattern="leaf"`. The existing material factory now selects `Aaris/Procedural Foliage` only for that pattern. Buildings, terrain, roads, water and tree trunks stay on their existing materials. All placement IDs, transforms, cell ownership and fixed trunk colliders are unchanged.

`SandboxInput` -> `PhysicsPawn` / `PhysicsWeapon` -> physics / render camera remains independent. Cosmetic wind never updates gameplay state, physics, network messages or the source JSON. Each phone computes the shader animation at render time.

### Changes implemented

1. **GPU foliage sway:** vertex wind offsets with per-tree spatial phase, smooth time-varying gusts and local-height damping. Wind parameters are clamped by shader properties and can be set to zero in the generated foliage materials. Geometry is still the original three shared LOD meshes; no CPU per-tree update or allocations were introduced.
2. **Matching shadow and depth geometry:** forward, ShadowCaster and DepthOnly passes use the same displacement function. This avoids placing wind-animated leaves over completely static leaf shadows or depth prepass geometry.
3. **Compact mesh index buffers:** the mesh builder now selects 16-bit indices for meshes with at most 65,535 vertices, retaining 32-bit support for larger meshes. This reduces index-buffer bytes for eligible authored meshes but does not establish an FPS gain without profiling.
4. **Focused Unity EditMode assertions:** test shader import, foliage binding, retained trunk collider and 16-bit terrain tile index format. These tests still require an actual Unity runner.

### Safety, quality and remaining risks

- The shader is intentionally visual-only. Do not transmit leaf positions over the network. The shared wind motion is not an authoritative, bitwise-deterministic simulation, and is not intended for hitbox interaction.
- The foliage geometry is procedural development art, *not* realistic leaf cards or PBR-scanned vegetation. The current sandbox pawn is not a rigged or animated human. Better realism requires an original/licensed character rig, movement animations, surface detail and art direction.
- The authored tree collider represents the trunk and remains unaffected by swaying leaves. When future foliage becomes physical cover, its collision specification must be explicit and validated.
- LODGroup source bounds do not automatically expand for shader displacement. Sway is deliberately limited to a small amplitude. Unity camera-culling and shadow artefacts must be checked on device.
- Source checks cannot compile HLSL or measure CPU/GPU load. Run shader import, EditMode tests, render comparisons, GPU profiling and device QA before merge or release.

### Acceptance checklist (manual, no APK by default)

- On a licensed Unity 6000.3.26f1 editor, run `bash Tools/unity-review.sh compile` then `bash Tools/unity-review.sh test`. Check that the foliage shader imports without errors and the generated tree material uses it.
- Open the world/sandbox scene in Play Mode; compare 0 and 0.12 m `_WindStrength`. Confirm visible motion, no moving trunk collider, plausible shadows, no depth popping and smooth LOD transitions.
- Profile the same camera route on representative low-, mid- and high-range Android devices. Record median, 1% low and 99th-percentile frame time, GPU time, draw calls, RAM, thermal throttling and battery drain. No performance claims should be accepted without measured evidence.
- Verify the world source hash, placement IDs, original scene compilation, sandbox movement/fire controls, and other .NET and Unity tests remain unchanged.

### Subsequent milestones — not implemented in this PR

1. Replace blockout buildings, trees and the capsule avatar with original/licensed production-quality assets; introduce humanoid rig, retargeted animation, locomotion blending, foot placement and authored traversal affordances.
2. Implement measured async cell asset streaming: cancellable Addressables loads, owner-reference deduplication, collider-safe lifecycle, preload margin, hysteresis, pooled props and HLOD proxies; existing `StreamingPlanner` is only a policy selector.
3. Complete the gameplay loop: deliberate drop zones/loot economy, safe-zone pacing, cover and route fairness, final road collision, swimming/climbing/vaulting, multiple weapons, feedback/VFX and accessible HUD.
4. Add secure server-authoritative multiplayer, replication interest management, rewind/hit validation, anti-cheat controls, bots and 99/100-player soak testing; none are in the current sandbox.
5. Offer explicit mobile graphics tiers and profile-guided dynamic resolution/shadow/vegetation budgets *after* per-device measurements. Avoid implementing unnecessary high-end PC features on low-end mobile hardware.

### Public technical references

- [Unity: lighting methods for custom URP shaders](https://docs.unity.cn/2023.3/Documentation/Manual/urp/use-built-in-shader-methods-lighting.html)
- [Unity: shadow methods for custom URP shaders](https://docs.unity.cn/6000.0/Documentation/Manual/urp/use-built-in-shader-methods-shadows.html)
- [Unity: GPU instancing](https://docs.unity.cn/6000.2/Documentation/Manual/GPUInstancing.html)
- [Epic: World Partition and HLOD concepts](https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition---hierarchical-level-of-detail-in-unreal-engine)
- [RecastNavigation: public navmesh/pathfinding reference](https://github.com/recastnavigation/recastnavigation)
- [VK/Ev's MIT-licensed open shader examples (research only)](https://github.com/VKev/Unity-URP-Shaders-Code)

This implementation is original source written for Aaris; links are conceptual references, not copied engine code. Professional graphical parity or superiority has not been proven.
