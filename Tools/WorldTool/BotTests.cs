using Aaris.World;

namespace Aaris.Tools;

public static class BotTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("50 local bots use safe deterministic placement", FiftyBots);
        yield return ("100 local bots preserve stable unique IDs", HundredBots);
        yield return ("local bot planning is invariant to input object order", OrderStable);
        yield return ("unbounded local bot combat budgets are rejected", BudgetLimits);
        yield return ("local winner requires living player and no bots", VictoryConditions);
        yield return ("bot shooting requires visibility, range and cooldown", ShotConditions);
    }

    private static void Assert(bool ok, string why = "Bot invariant failed")
    {
        if (!ok) throw new Exception(why);
    }
    private static (WorldSpec world, AssetRegistry assets, SandboxSpec sandbox) Source()
    {
        return (WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath),
                WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath),
                WorldFiles.Read<SandboxSpec>("Assets/GameData/World/sandbox.json"));
    }
    private static void FiftyBots()
    {
        var (w, a, s) = Source();
        Assert(s.bots.enabled && s.bots.count == 50);
        Assert(SandboxValidator.Validate(s, w, a).Count == 0, "Current authored sandbox should validate.");
        var first = BotSpawnPlanner.Generate(w, a, s);
        var again = BotSpawnPlanner.Generate(w, a, s);
        Assert(first.Length == 50 && again.Length == 50);
        for (int i = 0; i < first.Length; i++)
        {
            Assert(first[i].id == again[i].id && first[i].x == again[i].x && first[i].z == again[i].z);
            Assert(WorldValidator.Inside(w.grid, first[i].x, first[i].z));
            for (int j = 0; j < i; j++)
                Assert(Geometry.PlanarDistance(first[i].x - first[j].x,
                                               first[i].z - first[j].z) >= 10);
        }
    }
    private static void HundredBots()
    {
        var (w, a, s) = Source();
        s.bots.count = 100;
        Assert(SandboxValidator.Validate(s, w, a).Count == 0, "100 bounded bots should pass authoring.");
        var bots = BotSpawnPlanner.Generate(w, a, s);
        Assert(bots.Length == 100);
        Assert(bots.Select(x => x.id).Distinct(StringComparer.Ordinal).Count() == 100);
        Assert(bots[0].id == "BOT_001" && bots[99].id == "BOT_100");
    }
    private static void OrderStable()
    {
        var (w, a, s) = Source();
        var before = BotSpawnPlanner.Generate(w, a, s);
        Array.Reverse(w.objects);
        Array.Reverse(a.assets);
        var after = BotSpawnPlanner.Generate(w, a, s);
        Assert(before.Length == after.Length);
        for (int i = 0; i < before.Length; i++)
            Assert(before[i].id == after[i].id && before[i].x == after[i].x &&
                   before[i].z == after[i].z);
    }
    private static void BudgetLimits()
    {
        var (w, a, s) = Source();
        s.bots.count = 101;
        Assert(SandboxValidator.Validate(s, w, a).Count > 0);
        s.bots.count = 50;
        s.bots.decisionsPerStep = 100;
        Assert(SandboxValidator.Validate(s, w, a).Count > 0);
        s.bots.decisionsPerStep = 4;
        s.bots.secondsPerShot = double.NaN;
        Assert(SandboxValidator.Validate(s, w, a).Count > 0);
    }
    private static void VictoryConditions()
    {
        Assert(LocalMatchRules.Outcome(100, 100) == LocalMatchOutcome.Running);
        Assert(LocalMatchRules.Outcome(1, 1) == LocalMatchOutcome.Running);
        Assert(LocalMatchRules.Outcome(0, 100) == LocalMatchOutcome.Won);
        Assert(LocalMatchRules.Outcome(0, 0) == LocalMatchOutcome.Lost);
        try { LocalMatchRules.Outcome(-1, 1); throw new Exception("Negative living count accepted."); }
        catch (ArgumentException) { }
    }
    private static void ShotConditions()
    {
        Assert(LocalMatchRules.CanFire(40, 48, true, 2, 1));
        Assert(!LocalMatchRules.CanFire(40, 48, false, 2, 1));
        Assert(!LocalMatchRules.CanFire(49, 48, true, 2, 1));
        Assert(!LocalMatchRules.CanFire(40, 48, true, 0.9, 1));
        Assert(!LocalMatchRules.CanFire(double.NaN, 48, true, 2, 1));
    }
}
