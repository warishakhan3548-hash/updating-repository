using Aaris.World;

namespace Aaris.Tools;

public static class GameplayTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("sandbox data and spawn footprints validate on the actual map", CurrentSandbox);
        yield return ("physics budgets include the dynamic player", BodyBudget);
        yield return ("invalid capsule and nonfinite movement are rejected", MovementLimits);
        yield return ("unbounded physics time and weapon cadence are rejected", TimingLimits);
        yield return ("sandbox spawns reject bounds, water and object overlap", SpawnSafety);
        yield return ("sandbox actor identities cannot duplicate world identities", SpawnIds);
        yield return ("jump without ground or request cannot occur", NoFreeJump);
        yield return ("coyote jump expires and never permits double jumps", Coyote);
        yield return ("buffered jump fires once on landing within its window", BufferedJump);
        yield return ("expired jump input does not fire after landing", ExpiredJump);
        yield return ("weapon rate is bounded without catching up after a hitch", FireCadence);
        yield return ("weapon reload conserves total ammunition", AmmoConservation);
        yield return ("reload blocks firing until its deadline", ReloadTiming);
        yield return ("empty weapon cannot fire or invent reserve ammunition", EmptyWeapon);
        yield return ("weapon refuses backward or nonfinite simulation clocks", WeaponClock);
        yield return ("move look and fire have independent stable finger owners", Multitouch);
        yield return ("lifting one finger cannot cancel another control", FingerRelease);
        yield return ("duplicate owners and out-of-bounds touches are rejected", DuplicateTouch);
        yield return ("touch cancellation clears every held control", CancelTouch);
        yield return ("sandbox JSON rejects ambiguous or unknown tuning fields", StrictSandbox);
    }
    private static void Assert(bool ok, string message = "Gameplay invariant failed.") { if (!ok) throw new Exception(message); }
    private static void Throws(Action action)
    { try { action(); } catch (ArgumentException) { return; } throw new Exception("Expected clock rejection."); }
    private static (SandboxSpec s, WorldSpec w, AssetRegistry a) Fixture()
        => (new SandboxSpec { player = new SpawnSpec { id = "Player", x = -30, z = -30 } },
            new WorldSpec { schemaVersion = 2, id = "PhysicsTest", terrain = new TerrainSpec { amplitude = 0 } }, new AssetRegistry { schemaVersion = 2 });
    private static void Bad(SandboxSpec s, WorldSpec w, AssetRegistry a) => Assert(SandboxValidator.Validate(s, w, a).Count > 0, "Unsafe sandbox accepted.");
    private static void CurrentSandbox()
    {
        var s = WorldFiles.Read<SandboxSpec>("Assets/GameData/World/sandbox.json"); var w = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath); var a = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
        Assert(SandboxValidator.Validate(s, w, a).Count == 0, string.Join("\n", SandboxValidator.Validate(s, w, a)));
    }
    private static void BodyBudget() { var (s, w, a) = Fixture(); s.maxDynamicBodies = 1; s.props = new[] { new PropSpec { id = "Box" } }; Bad(s, w, a); }
    private static void MovementLimits()
    {
        var (s, w, a) = Fixture(); s.movement.radius = 0.6; s.movement.height = 1; Bad(s, w, a);
        s.movement = new() { walkSpeed = double.NaN }; Bad(s, w, a);
    }
    private static void TimingLimits()
    {
        var (s, w, a) = Fixture(); s.fixedHz = 1000; Bad(s, w, a);
        s.fixedHz = 50; s.weapon.roundsPerSecond = 100; Bad(s, w, a);
    }
    private static void SpawnSafety()
    {
        var (s, w, a) = Fixture(); s.player.x = -512; Bad(s, w, a);
        s.player.x = -30; w.terrain.lakes = new[] { new LakeSpec { id = "Water", x = -30, z = -30 } }; Bad(s, w, a);
        w.terrain.lakes = Array.Empty<LakeSpec>();
        a.assets = new[] { new AssetSpec { id = "wall" } }; w.objects = new[] { new ObjectSpec { id = "Wall", asset = "wall", x = -30, z = -30 } }; Bad(s, w, a);
    }
    private static void SpawnIds() { var (s, w, a) = Fixture(); s.targets = new[] { new SpawnSpec { id = s.player.id } }; Bad(s, w, a); }
    private static void NoFreeJump()
    { var j = new JumpGate(0.1, 0.12); Assert(!j.Tick(0, true)); j.Reset(); j.Request(0); Assert(!j.Tick(0, false)); }
    private static void Coyote()
    {
        var j = new JumpGate(0.1, 0.12); j.Tick(0, true); j.Request(0.08); Assert(j.Tick(0.08, false));
        j.Request(0.09); Assert(!j.Tick(0.09, false)); j.Reset(); j.Tick(0, true); j.Request(0.11); Assert(!j.Tick(0.11, false));
    }
    private static void BufferedJump()
    {
        var j = new JumpGate(0.1, 0.12); j.Request(0.1); Assert(!j.Tick(0.1, false)); Assert(j.Tick(0.2, true)); Assert(!j.Tick(0.22, true));
    }
    private static void ExpiredJump() { var j = new JumpGate(0.1, 0.12); j.Request(0); Assert(!j.Tick(0, false)); Assert(!j.Tick(0.2, true)); }
    private static void FireCadence()
    {
        var gun = new WeaponState(new()); int shots = 0;
        for (int i = 0; i < 1000; i++) if (gun.Tick(i / 1000.0, true, false)) shots++;
        Assert(shots == 8); int before = gun.Ammo; Assert(gun.Tick(100, true, false)); Assert(!gun.Tick(100, true, false)); Assert(before - gun.Ammo == 1);
        var fixedGun = new WeaponState(new()); int fixedShots = 0;
        for (int i = 0; i < 50; i++) if (fixedGun.Tick(i * 0.02, true, false)) fixedShots++;
        Assert(fixedShots == 8, "Fixed-step rounding caused weapon cadence to drift.");
    }
    private static void AmmoConservation()
    {
        var gun = new WeaponState(new() { magazine = 3, reserve = 2, roundsPerSecond = 10, reloadSeconds = 1 });
        gun.Tick(0, true, false); gun.Tick(0.1, true, false); gun.Tick(0.2, true, false); gun.Tick(0.3, false, true); gun.Tick(1.3, false, false);
        Assert(gun.Ammo == 2 && gun.Reserve == 0 && gun.Ammo + gun.Reserve + 3 == 5);
    }
    private static void ReloadTiming()
    {
        var gun = new WeaponState(new() { reloadSeconds = 1 }); gun.Tick(0, true, false);
        Assert(!gun.Tick(0.1, true, true)); Assert(!gun.Tick(1.099, true, false)); Assert(gun.Tick(1.1, true, false)); Assert(gun.Ammo == 29);
    }
    private static void EmptyWeapon()
    {
        var gun = new WeaponState(new() { magazine = 1, reserve = 0 }); Assert(gun.Tick(0, true, false));
        Assert(!gun.Tick(100, true, true) && gun.Ammo == 0 && gun.Reserve == 0 && !gun.Reloading);
    }
    private static void WeaponClock() { var gun = new WeaponState(new()); gun.Tick(2, false, false); Throws(() => gun.Tick(1, true, false)); Throws(() => gun.Tick(double.NaN, false, false)); }
    private static void Multitouch()
    {
        var t = new TouchOwnership(); Assert(t.Begin(9, 0.15, 0.2)); Assert(t.Begin(31, 0.5, 0.6)); Assert(t.Begin(6, 0.9, 0.4));
        Assert(t.Get(6, out var role, out _) && role == TouchRole.Fire); Assert(t.Held(TouchRole.Move) && t.Held(TouchRole.Look) && t.Held(TouchRole.Fire));
    }
    private static void FingerRelease()
    {
        var t = new TouchOwnership(); t.Begin(0, 0.15, 0.2); t.Begin(1, 0.9, 0.4); t.End(0); t.End(999);
        Assert(t.Count == 1 && t.Held(TouchRole.Fire) && !t.Held(TouchRole.Move));
    }
    private static void DuplicateTouch()
    {
        var t = new TouchOwnership(); Assert(t.Begin(0, 0.9, 0.4)); Assert(!t.Begin(0, 0.5, 0.5)); Assert(!t.Begin(1, 0.9, 0.4)); Assert(!t.Begin(2, -0.1, 0.1)); Assert(!t.Begin(3, double.NaN, 0.1));
    }
    private static void CancelTouch() { var t = new TouchOwnership(); t.Begin(0, 0.9, 0.4); t.Begin(1, 0.15, 0.2); t.Clear(); Assert(t.Count == 0 && !t.Held(TouchRole.Fire)); }
    private static void StrictSandbox()
    {
        string path = Path.GetTempFileName();
        try
        {
            foreach (string json in new[] { "{\"fixedHz\":50,\"fixedHz\":100}", "{\"fixedHz\":50,\"magicPhysics\":true}" })
            {
                File.WriteAllText(path, json); bool rejected = false;
                try { WorldFiles.Read<SandboxSpec>(path); }
                catch (Exception e) when (e is InvalidDataException || e is System.Text.Json.JsonException) { rejected = true; }
                Assert(rejected, "Ambiguous or unknown tuning key accepted.");
            }
        }
        finally { File.Delete(path); }
    }
}
