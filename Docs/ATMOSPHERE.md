# Local mobile atmosphere cycle — stacked draft

This is **an original Aaris atmosphere controller**, inspired by the design purpose of Free Fire Solara's day-to-dusk weather transitions. It does not copy Free Fire/PUBG source, art, weather effects, terrain, or layout.

## Execution and UI/state trace

`world.json` lighting values -> `UnityWorldCompiler.Compile` -> **original Sun** / procedural sky / ambient / fog -> one `AtmosphereCycle` component on that same Sun -> Play Mode clock -> pure `AtmosphereTimeline.Sample` -> at most once every 0.12 s -> sun intensity/color/rotation + 3 ambient colors + URP fog + clone-local skybox exposure.

- EditMode remains an unchanged static world review. The generated component begins sampling only in Play Mode.
- Fully local/single-player render effect. **No server, network sync, leaf-by-leaf physics or multiplayer state**; zero per-frame material allocations (one sky clone at startup).
- Default 720-second looping daylight-to-dusk-to-daylight profile; the Inspector can change cycle time from 120–7200 s, updates from 0.05–1 s. Brightness, fog and sun-angle offsets remain bounded.
- Disabling the component restores light, fog, ambient colors and original skybox, and destroys its temporary skybox clone.
- No rain droplets, clouds, sound, volumetric fog, weather-driven surfaces, cinematic post-processing or production art is claimed. The weather effect is **atmospheric haze only**; the lighting path is not physically based atmospheric scattering.
- Existing r4 source revision, all 381 placement IDs and transforms, 64 authoring cells, terrain colliders, sandbox, render pipeline and foliage-wind system are unchanged.

## Verification gates (not completed on the authoring workstation)

1. Run .NET 8 source tests: `dotnet run --project Tools/WorldTool -- self-test`, `validate`, `validate-sandbox` and `review`.
2. Run licensed Unity 6000.3.26f1 EditMode test `AtmosphereIntegrationTests`, and explicitly validate URP shaders.
3. Compare EditMode screenshots to baseline (must not change). In PlayMode check 0 / 180 / 360 / 540 / 720 s, verify no bright flashes on cycle wrap, and test disabling/re-enabling plus scene changes.
4. Profile low/mid/high Android target devices (CPU/GPU timing, fps/pacing, thermals and battery). Tune cadence or disable for slow devices. Do **not** infer phone FPS from pure source tests.

This feature branch stacks on `feature/foliage-wind-mobile-frame-pacing` (draft PR #686), so it cannot safely merge to `main` without reconciling that dependency. No APK/AAB build was requested or triggered intentionally.
