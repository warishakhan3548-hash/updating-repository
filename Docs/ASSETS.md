# Asset integration contract

The initial seven asset types are original procedural architectural blockouts: four building shells, a lookout tower, a boulder and a tree. No downloaded game assets, third-party character models or textures are bundled.

Every registry entry records dimensions, preview shape/color, origin, license and conservative cost estimates. A real replacement must be a Unity prefab below `Assets/Art/`, with a ground-centred pivot, local +Z entrance/front and dimensions consistent with its registered footprint. Set `prefabPath` to switch the compiler from the blockout to the prefab without changing permanent object IDs.

Before importing real art:

1. Record the creator, original download URL, license text, commercial usage/redistribution permission, source version and SHA-256 under `Assets/Art/<pack>/LICENSES/`.
2. Import a pinned local copy. Do not make every CI run download mutable online content.
3. Inspect bounds, colliders, materials, texture memory, animation rig and LODs in Unity. Replace estimated costs using the actual imported asset and add a target-phone measurement.
4. Verify building interiors, entrances, stairs, camera collision, terrain foundation and navigation. The shell blockout is not a validated gameplay building.

`validate --production` rejects blockout entries based on the registry's art metadata. This is an **art metadata gate only**; it does not verify file presence outside Unity, commercial readiness, licenses' legal sufficiency, shader compatibility or mobile performance. Unity compilation separately rejects missing prefab files. There is no production release pipeline in v1.

Large final assets may use Git LFS once hosting/build support and storage limits are chosen. This initial text-first project does not enable LFS or create a paid storage dependency.
