# Asset integration contract

Revision 2 has thirteen original procedural development asset types: several architectural styles, a tower, oak/pine trees, a boulder and cover props. All three LODs and material data are generated in shared C#; Unity template instances reuse meshes/materials. No downloaded game assets, third-party character models or textures are bundled.

Every registry entry records dimensions, preview shape/color, origin, license and conservative cost estimates. A real replacement must be a Unity prefab below `Assets/Art/`, with a ground-centred pivot, local +Z entrance/front and dimensions consistent with its registered footprint. Set `prefabPath` to switch the compiler from the blockout to the prefab without changing permanent object IDs.

Before importing real art:

1. Record the creator, original download URL, license text, commercial usage/redistribution permission, source version and SHA-256 under `Assets/Art/<pack>/LICENSES/`.
2. Import a pinned local copy. Do not make every CI run download mutable online content.
3. Inspect bounds, colliders, materials, texture memory, animation rig and LODs in Unity. Replace estimated costs using the actual imported asset and add a target-phone measurement.
4. Verify building interiors, entrances, stairs, camera collision, terrain foundation and navigation. The shell blockout is not a validated gameplay building.

`validate --production` rejects blockout entries based on the registry's art metadata. This is an **art metadata gate only**; it does not verify file presence outside Unity, commercial readiness, licenses' legal sufficiency, shader compatibility or mobile performance. Unity compilation separately rejects missing prefab files. There is no production release pipeline.

Large final assets may use Git LFS once hosting/build support and storage limits are chosen. This initial text-first project does not enable LFS or create a paid storage dependency.

Procedural development art uses empty `prefabPath` plus an explicit `archetype`. Its material data is original, generated from math patterns, with no external texture downloads. The production-art gate continues to reject development assets until final art and engine/device validation are complete. Offline Blender rendering is available only while every asset uses its procedural source; prefab overrides must be reviewed in Unity.
