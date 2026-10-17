# Native Unity physics and local TPS sandbox

The tactical presentation upgrade adds the source-world minimap, heading/zone
guidance, safe-area HUD and original articulated development character. The
dependency/state map and acceptance boundary are in
[`TACTICAL-UPGRADE.md`](TACTICAL-UPGRADE.md).

The map is world revision 3; `Assets/GameData/World/sandbox.json` is a separate revisioned gameplay/physics source (currently r2). Compiling a sandbox reads the existing world and adds the local harness. It never rewrites world JSON or builds an Android player.

## Implemented code

- Native Unity 3D Rigidbody/capsule player, metre/kilogram/second units, 9.81 m/s² gravity, 50 Hz fixed simulation and at most four catch-up steps. A long hitch deliberately slows simulation time rather than allowing an unbounded catch-up spiral.
- Acceleration-limited ground/air steering, normalized diagonal movement, sprint, moving-support point velocity, slope projection and steep-slope uphill rejection. Capsule collision, `ContinuousDynamic` and interpolation are configured on the native body. Gravity remains the engine's responsibility.
- Jump launch speed derives from `sqrt(2*g*height)`. Buffered requests and a short coyote window are consumed once; a ground-probe suppression interval prevents the launch from immediately becoming another grounded jump. Native engine integration tests check the resulting trajectory and collisions, but have not run here.
- Static terrain/building meshes stay static. Six separate box props use primitive colliders, bounded masses, material friction and native collision/impact impulses. The current scene has seven dynamic bodies including the player; the source cap is 24. Concave building meshes are never attached to dynamic Rigidbodies.
- Stable finger IDs own move/look/fire/jump/reload/aim/sprint roles. Look uses displacement per safe-area short edge, with no extra frame-time multiplication. Two thumbs can move and drag the fire button to aim/shoot. Dragging the move stick beyond its normal forward radius requests sprint. Focus loss, pause, orientation/safe-area change and cancelled touches clear ownership.
- Third-person shoulder camera, swipe yaw/pitch, bounded recoil, aim FOV and sphere-sweep obstruction. Camera retraction is immediate; safe recovery is smoothed. Player visuals hide when the camera retracts very close.
- Local hitscan rifle, limited cadence, 30-round magazine, finite reserve, timed reload, head/body target regions, damage/death/reset and one reusable tracer. Missed shots never accumulate into a burst after a hitch.
- Camera aim chooses a point, then a chest-to-muzzle and muzzle-to-point query respects nearby cover. An overlap at the chest blocks the shot instead of firing a ray from inside solid geometry. Queries use the owning PhysicsScene. Shooting originates at the authoritative Rigidbody position rather than an interpolated render transform.

## Native scene generation

```bash
dotnet run --project Tools/WorldTool -- validate-sandbox
export UNITY_EDITOR=/path/to/licensed/Unity
bash Tools/unity-review.sh sandbox
bash Tools/unity-review.sh test
```

Open the generated `Assets/Generated/PhysicsSandbox.unity` in Unity Play Mode for interaction. Desktop: WASD, Shift, Space, R, left mouse fire, right mouse aim/look. Phone controls use Unity's native legacy touch module and a development IMGUI overlay. This overlay is a diagnostic harness, not final mobile UI, art, animation or an accessibility-tested input system.

Layers 8–11 are reserved for AarisWorld/AarisProp/AarisPlayer/AarisTarget; compilation rejects occupied layer slots. The session applies and restores its global simulation time, gravity, transform-sync and collision-layer policy. Only one session may own these global settings. No runtime manual simulation is mixed with FixedUpdate. Isolated EditMode tests simulate their own native physics scenes manually.

## Validation boundary

119 .NET core/tool tests cover source safety, budgets, jump timing, touch ownership, ammunition/cadence/reload, tactical map projection/compass/guidance, zone shape/world-edge safety and all previous world invariants. These tests do not execute Unity, PhysX, input hardware, rendering or actual collision callbacks.

Unity EditMode tests are authored for world/render behavior, isolated native physics/combat/camera behavior, sandbox assembly and character presentation. They remain **pending** a licensed Unity runner. Do not call movement, collision, headshots, CCD, character poses, UI rendering or frame rate verified from the .NET results. CCD is a mitigation, not a guarantee against tunnelling under arbitrary geometry, scale or speed.

## Distance from the requested finished battle royale

| Area | Current milestone | Remaining before commercial comparison |
| --- | --- | --- |
| Map | 1.024 km square, six districts, bounded density, redundant routes | Sight-line/navigation analysis, entrances/stairs/climb routes, loot/spawn fairness, extensive playtests |
| Art | Original parameterized development buildings/trees/materials | Final licensed/original assets, rigs/animations, audio, environment polish and device visual review |
| Movement | Native physics implementation and local input harness | Actual engine/device checks, stairs/step handling, crouch/vault/climb/swim, animation and camera polish |
| Combat | One local hitscan rifle and three stationary targets | Weapon families, inventory/loot, animation/audio, bots, ballistic/explosion design and balance |
| World runtime | Fully loaded review/sandbox scene and a tested cell-selection planner | Async streaming/collider lifecycle, Addressables, HLOD, pooling and device profiling |
| Online match | Not implemented | Authoritative server, replication, lag compensation, matchmaking, anti-cheat and operations |

There is no defensible percentage for being better/worse than a shipped game at this stage. Do not substitute more houses, high texture resolution, engine selection or a test count for measured gameplay/visual quality. Water is currently visual; there is no swimming/buoyancy. Props are local sandbox bodies, not persistent or network-synchronized gameplay objects. Ragdolls, vehicles, destructible terrain and complete battle-royale match rules are not implemented.

## Primary API references

- [Rigidbody and native forces](https://docs.unity3d.com/6000.3/Documentation/ScriptReference/Rigidbody.AddForce.html)
- [PhysicsScene simulation and fixed step](https://docs.unity3d.com/6000.3/Documentation/ScriptReference/PhysicsScene.Simulate.html)
- [Stable touch finger IDs](https://docs.unity3d.com/6000.3/Documentation/ScriptReference/Touch-fingerId.html)
- [Physics sphere sweep](https://docs.unity3d.com/6000.3/Documentation/ScriptReference/PhysicsScene.SphereCast.html)

These support the implementation choices; the native engine/device acceptance gate remains necessary.

The collision/visibility audit is documented in `AUDIT.md`. Fresh jump/reload pulses expire against wall time, lost finger IDs are pruned, camera volumes are overlap-checked and firing is blocked without a clear camera pose. Collision roof panels now have a closed underside. Native verification remains pending.

## Battle-zone authoring milestone (sandbox revision 2)

The checked-in local test sandbox now uses a configurable **moving, shrinking circular battle zone**. It waits 45 seconds, then moves from (0, 0) to (260, 245) while shrinking from 490 m to 75 m over 220 seconds. The final centre is near Orchard Depot. A world-ground-following 96-segment cyan outline is refreshed at most twice per second; physics queries ignore dynamic actors. Outside the boundary the local player loses 4 health per simulation second, with a whole-capsule margin. Zero health restarts the local sandbox and zone clock; this is **not** a multiplayer knockout or revival implementation.

The safe-circle nesting invariant is enforced at source validation: the total centre shift may not exceed the total radius decrease. The pure timeline is independent of frame rate and has boundary, non-finite input and nested-circle tests. HUD shows player health, phase, countdown and outside distance. The old world revision and its existing placements are not modified, and no APK build is triggered. Shader compilation, LineRenderer visuals, native timing and performance still require Unity editor/device acceptance.
