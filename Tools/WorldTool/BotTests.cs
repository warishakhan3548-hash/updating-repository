using Aaris.World;

namespace Aaris.Tools;

public static class BotTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("50 local bots spawn deterministically and clear authored geometry", FiftyBots);
        yield return ("100 local bots stay within world and initial safe zone", HundredBots);
        yield return ("invalid bot counts and no-safe-spawn map are rejected", BadBots);
    }
    private static (WorldSpec world, AssetRegistry registry, SandboxSpec sandbox) Load()
    {
        var w = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath);
        var a = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
        var s = WorldFiles.Read<SandboxSpec>("Assets/GameData/World/sandbox.json");
        s.bots.enabled = true;
        return (w, a, s);
    }
    private static void Assert(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
    }
    private static void FiftyBots()
    {
        var (w, a, s) = Load();
        s.bots.count = 50;
        var first = BotSpawnPlanner.Generate(w, a, s);
        var repeat = BotSpawnPlanner.Generate(w, a, s);
        Assert(first.Length == 50 && repeat.Length == first.Length, "Bot count is wrong.");
        var ids = new HashSet<string>();
        for (int i = 0; i < first.Length; i++)
        {
            Assert(first[i].id == repeat[i].id && first[i].x == repeat[i].x && first[i].z == repeat[i].z,
                "Bot spawn seed is not repeatable.");
            Assert(ids.Add(first[i].id), "Duplicate bot identity.");
            foreach (var lake in w.terrain.lakes)
            {
                double dx = (first[i].x - lake.x) / lake.radiusX, dz = (first[i].z - lake.z) / lake.radiusZ;
                Assert(dx * dx + dz * dz >= 1, "Bot spawned in water.");
            }
        }
    }
    private static void HundredBots()
    {
        var (w, a, s) = Load();
        s.bots.count = 100;
        var placed = BotSpawnPlanner.Generate(w, a, s);
        Assert(placed.Length == 100, "Did not place 100 bots.");
        foreach (var b in placed)
        {
            Assert(b.x > w.grid.originX && b.x < w.grid.originX + w.grid.sizeX &&
                b.z > w.grid.originZ && b.z < w.grid.originZ + w.grid.sizeZ, "Bot outside map.");
            var z = s.zone;
            double dx = b.x - z.startX, dz = b.z - z.startZ;
            Assert(dx * dx + dz * dz <= z.startRadius * z.startRadius, "Bot started outside safe zone.");
        }
    }
    private static void BadBots()
    {
        var (w, a, s) = Load();
        s.bots.count = 101;
        Assert(SandboxValidator.Validate(s, w, a).Count != 0, "Accepted >100 bots.");
        bool rejected = false;
        try { BotSpawnPlanner.Generate(w, a, s); }
        catch (ArgumentException) { rejected = true; }
        Assert(rejected, "Planner accepted >100 bots.");
        s.bots.count = 50;
        w.grid.sizeX = w.grid.sizeZ = 12;
        rejected = false;
        try { BotSpawnPlanner.Generate(w, a, s); }
        catch (InvalidOperationException) { rejected = true; }
        Assert(rejected, "Planner invented spawns on a tiny map.");
    }
}
