# Milestone 1 status

Implemented: Unity/C# project scaffold; versioned source data; deterministic terrain; stable object/asset IDs; rotated overlap, road clearance and terrain checks; owner/reference cell plans; estimated per-cell budgets; revision-checked moves; schematic review; Unity scene compiler and PNG exporter source; no-APK GitHub checks.

Initial world: `Aaris_Highlands`, revision 1, 1024 × 1024 m, 128 m cells, 4 districts, 72 placements and 3 road polylines.

## Verification performed in the authoring environment

- The shared C# core and command tool compiled using .NET SDK 8.0.413's Roslyn compiler against .NET 8 reference assemblies, with code warnings treated as errors.
- All **38 C# regression/invariant tests passed**.
- Checked-in sample passed world validation, repeated canonical compilation and the example marker move dry run.
- The schematic preview and metrics were generated directly from the checked-in source. The PNG in `Docs/Review/` is a rasterized schematic, not a Unity screenshot.

The local execution environment's process metadata prevented the SDK's normal `dotnet build/run` frontend from starting. Verification used the SDK's actual C# compiler and .NET runtime directly, rather than claiming the normal frontend had passed. The GitHub workflow uses normal `dotnet build/run`; its run status is recorded on GitHub.

## Still requires a Unity runner

Unity import/package resolution, editor compilation, three EditMode integration tests and actual URP perspective rendering have **not been executed locally**. They require Unity 6000.3.26f1 and a valid license, plus a graphics-capable runner for PNG export. Scripts and integration tests are included. No Unity Cloud service was provisioned or billed.

No APK/AAB was built. Runtime streaming/Addressables, LOD/HLOD, final models/textures, mobile controls, player movement, weapons, bots, networking and target-device performance validation are later work. Do not label this foundation as a commercial-ready game.
