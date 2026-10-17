# Tactical presentation upgrade

This change develops the existing native Unity local practice sandbox. It adds
world-aware navigation and original humanoid development art; it does not turn
the project into a finished multiplayer battle royale.

## Dependency and state map

```text
world.json + assets.json             sandbox.json
  terrain, roads, districts            movement, weapon, zone
            |                                  |
        WorldValidator / SandboxValidator / shared C# core
            |                                  |
        UnityWorldCompiler --> PhysicsSandboxCompiler
                                |            |
                   static world + read-only  capsule + visual humanoid
                   tactical source snapshot  + local targets/props
                                |            |
                          SandboxSession <--- PhysicsPawn / PhysicsWeapon
                                |                 ^
                           SandboxHud          SandboxInput
                                |
                  TacticalMinimap + TacticalNavigation
```

Touch/keyboard input changes the native pawn velocity and camera yaw. The visual
root follows yaw; its child limbs provide a velocity-driven presentation without
moving the physics body. The weapon still resolves camera aim through chest and
muzzle obstruction checks. Health, ammunition, pawn position, camera heading and
the moving-zone snapshot feed the HUD. Tactical projection uses +Z north and a
top-left display origin so world, compass and minimap agree.

The world JSON remains the authoritative map. The generated scene stores a
read-only snapshot for its map display; rebuilding the scene updates that snapshot.
No alternate hand-edited map, imported game art or generated scene YAML is added.

## Changes and boundaries

- A cached north-up minimap presents the existing world and its districts, the
  local player's facing, the current zone and the authored final zone.
- The HUD presents health, ammunition, heading and safe-zone information in the
  screen safe area, alongside the existing shared mobile-control rectangles.
- A safe-zone direction is a direct geometric bearing, not a promise of a
  walkable path. Buildings, water and terrain may require a different route.
- A proportioned procedural humanoid replaces the single capsule visual. Its
  equipment and locomotion are original development art, not final character
  meshes, motion-captured animation or photorealism. The existing collision
  capsule remains the gameplay body.
- Pure C# policies capture map bounds, preserve rectangular-world aspect, handle
  compass wrap and match the damage policy's existing capsule tolerance. They
  reject non-finite and unrepresentable queries.
- Zone source validation now requires a strictly shrinking circle fully inside
  the rectangular world. The runtime timeline also rejects nonpositive final
  radii and non-nested movement, preventing source/runtime disagreement.

Existing world placements and permanent IDs are retained. No world geometry was
changed, so the world revision remains 3 and sandbox settings remain revision 2.

## Benchmark research

Garena's [Free Fire overview](https://ff.garena.com/en/) describes short matches
and its main modes. The official [Solara introduction](https://ff.garena.com/en/article/1482/)
describes distinct areas, elevation and traversal. The official
[PUBG gameplay overview](https://www.pubg.com/en/game-info/overview) describes the
landing, looting, rotation and shrinking-zone survival loop.

Our design inference is to make the existing districts and zone rotation easier
to read before expanding match complexity. These sources do not establish our
implementation's balance, device performance or superiority to either game.

## Acceptance

Run the .NET self-tests, world/sandbox validators and schematic regeneration.
Pure tests cover projection, headings and zone destinations, not Unity rendering.
The core also needs the project's C# 9/.NET Standard 2.1 compatibility check.

On a licensed Unity 6000.3.26f1 runner, compile the sandbox and run EditMode tests.
In Play Mode inspect character scale/stride, rifle and muzzle alignment, camera
obstruction, minimap heading and zone motion. Check portrait/landscape safe areas
and simultaneous joystick/fire/look control. On representative phones measure
frame time, allocations, memory, thermal behavior and readability. These native
and device acceptance steps remain pending when no licensed editor is available.

No APK/AAB or release build is part of this upgrade. Realistic final art, audio,
inventory, bots, vehicles, runtime world streaming and authoritative online
multiplayer remain separate development work.
