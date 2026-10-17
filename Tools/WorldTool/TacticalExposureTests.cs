using Aaris.World;

namespace Aaris.Tools;

public static class TacticalExposureTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("tactical exposure distinguishes open ground from solid wall", WallVsOpen);
        yield return ("tactical exposure respects grid boundaries and invalid options", Bounds);
        yield return ("tactical exposure is deterministic and does not change sources", Determinism);
        yield return ("tactical exposure enforces work budget before ray builds", Budget);
    }
    private static void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
    private static void Reject(Action action)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        catch (InvalidOperationException) { return; }
        throw new Exception("Expected explicit tactical exposure rejection.");
    }
    private static WorldSpec Flat() => new WorldSpec
    {
        id = "tactical-fixture",
        grid = new GridSpec { originX = 0, originZ = 0, sizeX = 64, sizeZ = 64, cellSize = 64 },
        terrain = new TerrainSpec { baseHeight = 0, amplitude = 0, gridSpacing = 8 }
    };
    private static void WallVsOpen()
    {
        var w = Flat(); var terrain = new TerrainSampler(w);
        var options = new TacticalExposureOptions { spacing = 32, range = 24, directions = 8 };
        var empty = TacticalExposureReview.SampleAt(new CollisionBvh(Array.Empty<CollisionTriangle>()),
            terrain, w.grid, 32, 32, options);
        var wall = new CollisionBvh(new[]
        {
            new CollisionTriangle(new Point3(40, 0, 8), new Point3(40, 4, 8), new Point3(40, 4, 56), "cover"),
            new CollisionTriangle(new Point3(40, 0, 8), new Point3(40, 4, 56), new Point3(40, 0, 56), "cover")
        });
        var obstructed = TacticalExposureReview.SampleAt(wall, terrain, w.grid, 32, 32, options);
        Check(empty.standingOpen == 1 && empty.crouchOpen == 1, "Empty rays must remain open.");
        Check(obstructed.standingOpen < empty.standingOpen &&
              obstructed.crouchOpen < empty.crouchOpen &&
              obstructed.nearbyBlocked > 0, "Solid wall must change exposure and nearby blocker evidence.");
    }
    private static void Bounds()
    {
        var w = Flat(); var terrain = new TerrainSampler(w);
        var empty = new CollisionBvh(Array.Empty<CollisionTriangle>());
        Reject(() => TacticalExposureReview.SampleAt(empty, terrain, w.grid, -0.1, 32, new()));
        Reject(() => TacticalExposureReview.SampleAt(empty, terrain, w.grid, 64, 32, new()));
        Reject(() => TacticalExposureReview.SampleAt(empty, terrain, w.grid, double.NaN, 32, new()));
        Reject(() => TacticalExposureReview.SampleAt(empty, terrain, w.grid, 32, 32,
            new TacticalExposureOptions { standingEye = 1, crouchEye = 1 }));
        Reject(() => TacticalExposureReview.SampleAt(empty, terrain, w.grid, 32, 32,
            new TacticalExposureOptions { range = double.PositiveInfinity }));
    }
    private static void Determinism()
    {
        var w = Flat(); var terrain = new TerrainSampler(w);
        var bvh = new CollisionBvh(Array.Empty<CollisionTriangle>());
        var options = new TacticalExposureOptions { directions = 16 };
        string before = WorldFiles.Serialize(w);
        var first = TacticalExposureReview.SampleAt(bvh, terrain, w.grid, 25, 31, options);
        var second = TacticalExposureReview.SampleAt(bvh, terrain, w.grid, 25, 31, options);
        Check(WorldFiles.Serialize(first) == WorldFiles.Serialize(second), "Fixed sample must be repeatable.");
        Check(WorldFiles.Serialize(w) == before, "Analysis may not mutate source.");
    }
    private static void Budget()
    {
        var w = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath);
        var assets = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
        Reject(() => TacticalExposureReview.Analyze(w, assets,
            new TacticalExposureOptions { spacing = 16, maxSamples = 8 }));
        Reject(() => TacticalExposureReview.Analyze(w, assets,
            new TacticalExposureOptions { spacing = double.NaN }));
    }
}
