using Aaris.World;

namespace Aaris.Tools;

public static class LootTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("district supplies are bounded, land-safe and deterministic", LandSafe);
        yield return ("loot layout ignores source object/landmark ordering", Stable);
        yield return ("loot can be explicitly disabled and rejects invalid tuning", Settings);
        yield return ("ammunition pickups preserve bounded weapon-state invariants", Ammo);
    }

    private static void Check(bool yes, string message) { if (!yes) throw new Exception(message); }
    private static (WorldSpec w, AssetRegistry a, SandboxSpec s) Fixture()
        => (WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath),
            WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath),
            WorldFiles.Read<SandboxSpec>("Assets/GameData/World/sandbox.json"));

    private static void LandSafe()
    {
        var (w, a, s) = Fixture();
        var drops = LootPlanner.Generate(w, a, s);
        Check(drops.Length >= w.landmarks.Length && drops.Length <= s.loot.maxPickups,
            "Loot count must be useful but bounded.");
        Check(drops.Any(d => d.id == "LOOT_START_AMMO"), "Missing local starter supply.");
        var terrain = new TerrainSampler(w);
        var assets = a.assets.ToDictionary(x => x.id, StringComparer.Ordinal);
        Check(drops.Select(d => d.id).Distinct(StringComparer.Ordinal).Count() == drops.Length, "Duplicate loot IDs.");
        for (int i = 0; i < drops.Length; i++)
        {
            var d = drops[i];
            Check(WorldValidator.Finite(d.x, d.z) && WorldValidator.Inside(w.grid, d.x - 1.5, d.z - 1.5)
                && WorldValidator.Inside(w.grid, d.x + 1.5, d.z + 1.5), "Loot left playable bounds.");
            Check(terrain.SlopeDegrees(d.x, d.z) <= 25.01, "Loot on unsafe slope.");
            Check(!w.terrain.lakes.Any(l => Math.Pow((d.x - l.x) / (l.radiusX + 1.5), 2) +
                Math.Pow((d.z - l.z) / (l.radiusZ + 1.5), 2) <= 1), "Loot inside water.");
            var rect = Geometry.Footprint(new ObjectSpec { x = d.x, z = d.z },
                new AssetSpec { width = 2.4, depth = 2.4 });
            Check(!w.objects.Any(o => assets[o.asset].blocksPlacement &&
                Geometry.Overlaps(rect, Geometry.Footprint(o, assets[o.asset]))), "Loot intersects world obstacle.");
            for (int j = 0; j < i; j++)
                Check(Geometry.PlanarDistance(d.x - drops[j].x, d.z - drops[j].z) >= s.loot.minSpacing - 0.01,
                    "Supplies clustered inside minimum spacing.");
        }
    }

    private static void Stable()
    {
        var (w, a, s) = Fixture();
        string Key(LootDrop[] drops) => string.Join("|", drops.Select(d =>
            d.id + ":" + d.x.ToString("R", System.Globalization.CultureInfo.InvariantCulture) + ":" +
            d.z.ToString("R", System.Globalization.CultureInfo.InvariantCulture) + ":" + d.kind));
        var expected = Key(LootPlanner.Generate(w, a, s));
        Array.Reverse(w.objects);
        Array.Reverse(w.landmarks);
        Array.Reverse(a.assets);
        Check(expected == Key(LootPlanner.Generate(w, a, s)), "Authoring source order changed loot.");
        w.seed++;
        Check(expected != Key(LootPlanner.Generate(w, a, s)), "Seed did not affect district layout.");
    }

    private static void Settings()
    {
        var (w, a, s) = Fixture();
        Check(SandboxValidator.Validate(s, w, a).Count == 0, "Checked-in sandbox invalid.");
        s.loot.enabled = false;
        Check(LootPlanner.Generate(w, a, s).Length == 0, "Disabled loot must not generate objects.");
        s.loot.enabled = true;
        s.loot.maxPickups = 1000;
        Check(SandboxValidator.Validate(s, w, a).Count > 0, "Unlimited loot accepted.");
        s.loot.maxPickups = 24;
        s.loot.pickupRadius = double.NaN;
        Check(SandboxValidator.Validate(s, w, a).Count > 0, "Nonfinite pickup radius accepted.");
    }

    private static void Ammo()
    {
        var gun = new WeaponState(new WeaponSpec { magazine = 2, reserve = 0, roundsPerSecond = 10 });
        Check(gun.Tick(0, true, false), "Initial shot missing.");
        Check(gun.TryAddReserve(30) && gun.Ammo == 1 && gun.Reserve == 30,
            "Pickup must add reserve, not bypass reload.");
        Check(!gun.Tick(0.1, false, false) && gun.Ammo == 1, "Pickup should not fire.");
        Check(gun.TryAddReserve(200), "Valid pickup rejected.");
        for (int i = 0; i < 5; i++) gun.TryAddReserve(200);
        Check(gun.Reserve == 1000 && !gun.TryAddReserve(30), "Ammo capacity exceeded.");
        try { gun.TryAddReserve(0); throw new Exception("Zero amount accepted."); }
        catch (ArgumentOutOfRangeException) { }
    }
}
