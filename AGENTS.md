# Aaris development rules

- This repository is an original Unity/C# mobile 3D game project. Do not replace it with a browser game.
- The current milestone is world authoring. APK/AAB player builds must stay opt-in and must not run on source changes. Never trigger a release build unless the user asks for it.
- Edit `Assets/GameData/World/world.json` and `assets.json` as the world source. Do not hand-edit generated Unity scene YAML or copy generated files back as source.
- Preserve permanent object IDs. Increment the world revision for accepted world edits. Use the move tool's expected revision when moving existing objects.
- One source metre is one Unity unit; +Y is up, +Z is north; yaw follows Unity. Prefab pivot is ground-centred; scale is uniform.
- Read `Docs/ARCHITECTURE.md` and `Docs/STATUS.md` before expanding the foundation. Distinguish a tested authoring feature from a planned runtime feature.
- Run the C# self-tests, validate and regenerate the schematic after meaningful world/core changes. Unity editor changes also need an actual Unity compile/EditMode check on a licensed runner; never report it as passed if unavailable.
- Do not claim an engine preview, mobile performance, commercial readiness, multiplayer or final art from schematic previews or static metadata.
- Keep imported assets' provenance and license records. Do not silently fetch mutable online art during CI.
