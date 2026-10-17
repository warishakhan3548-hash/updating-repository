# Public references and applied design decisions

Reviewed 17 October 2026. These sources inform design; the numbers below are **Aaris authoring targets**, not claimed proprietary PUBG/Free Fire constants.

| Primary source | Relevant observation | Applied to Aaris |
| --- | --- | --- |
| [PUBG Update 29.1, Area Modifications](https://pubg.com/en-asia/news/7172?category=patch_notes) | The developer describes improving obstructive terrain/objects and adding ridgelines/objects where cover was limited. | Readable routes, nearby cover/slope checks, natural boulders and open meadow space. Destructible terrain was not implemented. |
| [Free Fire February 2025 patch](https://ff.garena.com/en/article/1456/) | Arsenal positions were adjusted to avoid clustering near the centre. | Six spaced districts with population ranges. This is our design inference, not Garena's placement algorithm. |
| [Free Fire Peak rework](https://ff.garena.com/en/article/1213/) | A major high-point location received a coherent building-layout rework. | Ridge Station has distinct elevation/architecture; the other districts have separate roles and palettes. |
| [Unity 6.3 URP performance settings](https://docs.unity3d.com/6000.3/Documentation/Manual/urp/configure-for-better-performance.html) | Unity recommends measurement, bounded shadow work, suitable batching and avoiding costly LOD cross-fades on lower-end mobiles. | Shared meshes/materials, 3 LODs without cross-fade, 2 MSAA samples, bounded shadow distance, two cascades. Device profiling is still required. |
| [Unity draw-call optimization choices](https://docs.unity3d.com/Manual/optimizing-draw-calls-choose-method.html) | Mesh/material reuse matters; SRP batching and GPU instancing have different applicability/priorities. | Cache per asset/LOD. Enable compatible instancing/SRP batching without claiming every object becomes one draw call. |
| [Epic World Partition HLOD](https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition---hierarchical-level-of-detail-in-unreal-engine) | Distant world geometry can use proxy meshes/materials. | Keep cell ownership/reference plans and add asset-level LOD. Runtime streaming and HLOD baking remain later work. |
| [Guerrilla: GPU-Based Procedural Placement in Horizon Zero Dawn](https://www.guerrilla-games.com/read/gpu-based-procedural-placement-in-horizon-zero-dawn) | Artist-authored placement rules drive environment generation. | Bounded authoring recipes combine biome, water, slope, road and corridor masks. Our generator is offline C#, not Guerrilla’s GPU runtime system. |
| [LIRIS: Procedural Generation of Roads (2010)](https://perso.liris.cnrs.fr/egalin/Articles/2010-roads.pdf) and [Mango technology transfer](https://perso.liris.cnrs.fr/apeytavi/website/project/mango/) | Terrain-weighted graph paths; related road/village research reached Ubisoft’s production engine. | Bounded A* proposals penalize elevation change and avoid water/obstacles; exact endpoints and rechecked shortcuts. Our simpler solver does not implement their curvature masks, cut/fill, tunnels or bridges. |

## Revision 4 implementation references

- [Unity 6.3 Android optimized frame pacing property](https://docs.unity.com/en-us/engine/6000.3/script-reference/unityeditor/playersettings/android/optimizedframepacing): use built-in frame pacing configuration rather than a custom timing loop.
- [Google Android Unity/ADPF best practices](https://developer.android.com/games/engines/unity/unity-adpf): device-specific quality and thermal adaptation are follow-on profiling work, not proven by static code.
- [Unity Technologies multiplayer reference](https://github.com/Unity-Technologies/U6-First-Person-Multiplayer): illustrates server-authoritative locomotion and networking; its 4-player co-op reference is not a ready-made 100-player battle royale engine.
- [Garena official maps](https://ff.garena.com/en/maps/): referenced for varied mobile battle environments, not copied assets, layouts or proprietary algorithms.
- [PUBG MOBILE Classic Mode description](https://play.google.com/store/apps/details?id=com.tencent.ig): last-survivor gameplay and large-match scope are future design targets, not capabilities already delivered by Aaris.

All implementation code and visual geometry here remain original. External samples were consulted for concepts, not pasted into the game.

## Aaris targets

- Six districts with 6–14 buildings each now; global cap 72 and anchor cap 9 buildings per 128 m cell.
- Building footprints remain within assigned districts. Meadows, woodland, slopes and shorelines are intentional land uses.
- Two or three distinct neighbouring districts per district; no single route-graph edge whose loss disconnects the network.
- Reserved 4 m walking corridors, source curves shared by validation/rendering and a sampled 25-degree route-slope target.
- Bounded tree counts per biome/cell; stable rejection sampling checks overlap, slope, roads, water and routes before accepting placements.
- Samples at terrain spacing (4 m now) measure nearby cover within 28 m and reject long uncovered runs. This proximity heuristic does not model shooter height, sight lines, destructibility or actual cover usefulness. Engine navigation/visibility checks and playtests must refine it.

## Visual direction

Warm plaster/roof districts, cool industrial/station roofs, tree silhouettes, biome tints, stone cover, shoreline colour and a calm lake provide original identity. Albedo/normal material data is generated deterministically; no copyrighted game models/textures were downloaded. Licensed final prefabs can later replace development geometry without changing object IDs.
