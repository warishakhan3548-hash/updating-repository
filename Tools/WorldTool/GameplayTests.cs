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
        yield return ("battle zone circles stay nested while shifting", ZoneNested);
        yield return ("battle zone wait shrink final boundaries are continuous", ZoneTiming);
        yield return ("battle zone respects capsule margin and outside distance", ZoneDistance);
        yield return ("battle zone rejects unsafe movement and impossible footprints", ZoneBadSettings);
        yield return ("battle zone timeline refuses nonfinite and backward clocks", ZoneBadClock);
        yield return ("offline bot tuning rejects unbounded counts and unsafe rates", BotLimits);
        yield return ("50 bots spawn reproducibly with safe locations and unique IDs", BotSpawns);
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
    private static BattleZoneSpec Zone() => new BattleZoneSpec
    { enabled = true, startX = 0, startZ = 0, endX = 260, endZ = 245, startRadius = 490, endRadius = 75,
      waitSeconds = 45, shrinkSeconds = 220, damagePerSecond = 4 };
    private static void ZoneNested()
    {
        var z = Zone(); var states = Enumerable.Range(0, 101).Select(i => BattleZoneTimeline.At(z, 45 + i * 2.2)).ToArray();
        for (int i = 1; i < states.Length; i++)
        {
            double dx = states[i].x - states[i-1].x, dz = states[i].z - states[i-1].z;
            Assert(Math.Sqrt(dx*dx + dz*dz) + states[i].radius <= states[i-1].radius + 1e-8, "Zone expands outside its prior circle.");
        }
    }
    private static void ZoneTiming()
    {
        var z = Zone(); var a = BattleZoneTimeline.At(z, 0); var b = BattleZoneTimeline.At(z, 45);
        var c = BattleZoneTimeline.At(z, 155); var d = BattleZoneTimeline.At(z, 265);
        Assert(a.phase == BattleZonePhase.Waiting && a.radius == z.startRadius && a.timeRemaining == 45);
        Assert(b.phase == BattleZonePhase.Shrinking && b.radius == z.startRadius);
        Assert(Math.Abs(c.radius - 282.5) < 1e-8 && Math.Abs(c.x - 130) < 1e-8);
        Assert(d.phase == BattleZonePhase.Final && d.radius == z.endRadius && d.timeRemaining == 0);
        Assert(BattleZoneTimeline.At(z, 100000).radius == z.endRadius);
    }
    private static void ZoneDistance()
    {
        var state = BattleZoneTimeline.At(Zone(), 265);
        Assert(!state.Outside(260, 245) && !state.Outside(335.3, 245, 0.35));
        Assert(state.Outside(337, 245, 0.35) && Math.Abs(state.ExcessDistance(337, 245, 0.35) - 1.65) < 1e-8);
    }
    private static void ZoneBadSettings()
    {
        var (s, w, a) = Fixture(); s.zone = Zone(); s.player.x = -30; s.player.z = -30;
        Assert(SandboxValidator.Validate(s, w, a).Count == 0);
        s.zone.endX = 430; Bad(s, w, a);
        s.zone = Zone(); s.zone.damagePerSecond = double.PositiveInfinity; Bad(s, w, a);
        s.zone = Zone(); s.zone.startRadius = 100; Bad(s, w, a);
        s.zone = Zone(); s.zone.endRadius = 490; Bad(s, w, a);
        s.zone = Zone(); s.zone.waitSeconds = -1; Bad(s, w, a);
    }
    private static void ZoneBadClock()
    {
        var z = Zone(); Throws(() => BattleZoneTimeline.At(z, -0.1));
        Throws(() => BattleZoneTimeline.At(z, double.NaN));
        Throws(() => BattleZoneTimeline.At(z, double.PositiveInfinity));
    }
    private static void BotLimits()
    {
        var (s, w, a) = Fixture(); s.bots.enabled = true; s.bots.count = 101; Bad(s, w, a);
        s.bots.count = 0; Bad(s, w, a);
        s.bots.count = 50; s.bots.moveSpeed = double.NaN; Bad(s, w, a);
        s.bots.moveSpeed = 4.3; s.bots.attackRange = 500; Bad(s, w, a);
        s.bots.attackRange = 42; s.bots.spawnSeparation = 0.1; Bad(s, w, a);
    }
    private static void BotSpawns()
    {
        var s = WorldFiles.Read<SandboxSpec>("Assets/GameData/World/sandbox.json");
        var w = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath);
        var a = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
        Assert(s.bots.enabled && s.bots.count == 50);
        var first = BotSpawnPlanner.Plan(s, w, a);
        var second = BotSpawnPlanner.Plan(s, w, a);
        Assert(first.Length == 50 && second.Length == 50);
        Assert(first.Select(b => b.id).Distinct(StringComparer.Ordinal).Count() == 50);
        for (int i = 0; i < first.Length; i++)
        {
            var bot = first[i];
            Assert(bot.id == second[i].id && bot.x == second[i].x && bot.z == second[i].z,
                "Offline bot layout must be exactly reproducible.");
            Assert(Math.Pow(bot.x - s.zone.startX, 2) + Math.Pow(bot.z - s.zone.startZ, 2) <
                s.zone.startRadius * s.zone.startRadius);
            for (int j = 0; j < i; j++)
                Assert(Math.Pow(bot.x - first[j].x, 2) + Math.Pow(bot.z - first[j].z, 2) >=
                    s.bots.spawnSeparation * s.bots.spawnSeparation, "Bot spawns overlap.");
        }
    }
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
