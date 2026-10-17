# Aaris World Foundation

Unity **6000.3.26f1 LTS** / C# / URP **17.3.0**. First milestone: an original, editable 3D world source and the tools to change and review it without rebuilding Android.

**भाई, अभी हर बदलाव पर APK नहीं बनेगा।** Map data और C# में काम होगा; checks और map review अलग हैं। Android build इस step में जोड़ा या चलाया नहीं गया है।

## What exists now

- A 1024 × 1024 m original Highlands layout: 64 cells, 4 named districts, 72 placements, roads, terrain pads and target markers.
- Engine-independent C# terrain sampler, rotated placement checks, cross-cell references and conservative authoring budgets.
- Stable IDs and revision-checked move commands, with validation before applying edits.
- Unity editor compiler for terrain meshes, modular architectural blockouts, prefab placements, URP lighting and a review scene.
- APK-free schematic/manifest generation and a separate Unity perspective PNG exporter.
- A small GitHub workflow that compiles/tests the C# authoring tool and produces a short-lived review bundle. It does not start Unity or make an APK.

![Schematic world layout, not a Unity render](Docs/Review/map-layout.png)

These are architectural blockouts for layout review. Final art, a playable character, guns and multiplayer are later milestones. This is not a finished commercial game. Actual Unity compilation/rendering still requires a licensed Unity runner; GitHub repository access does not provide one automatically.

## Authoring commands

Run from the repository root with .NET 8:

```bash
dotnet run --project Tools/WorldTool -- self-test
dotnet run --project Tools/WorldTool -- validate
dotnet run --project Tools/WorldTool -- review
dotnet run --project Tools/WorldTool -- move Tools/Commands/move-example.json
```

The example is a **dry run**: `BLD_COURTS_001` → `M001`. Add `--apply` to change source after validation. It increments the revision; adjust subsequent commands to the new revision. Invalid, ambiguous, overlapping or stale moves fail without changing the world. Commit the accepted source to preserve it; no Android build is required.

`Review/latest/` contains `top-view.svg`, `world-plan.json`, `metrics.json` and a README with the exact source hash. The schematic is a layout tool; it is not an engine screenshot. Checked-in `Docs/Review/` is the initial reviewed snapshot and must be regenerated when source changes.

## Unity authoring

Open the root as a Unity project, restore pinned packages and use **Aaris → World**. The same entry points can run on a licensed cloud editor:

```bash
export UNITY_EDITOR=/path/to/Unity
bash Tools/unity-review.sh compile
bash Tools/unity-review.sh test
# A graphics runner is required; on Linux, for example:
xvfb-run -a bash Tools/unity-review.sh render
```

These commands produce generated scene assets, EditMode results or PNGs, never a player build. `Assets/Generated/` and `Review/` are disposable outputs. The editor asks to save unsaved work before replacing the active scene.

Read [architecture](Docs/ARCHITECTURE.md), [current validation status](Docs/STATUS.md), and [asset contract](Docs/ASSETS.md) before adding systems.
