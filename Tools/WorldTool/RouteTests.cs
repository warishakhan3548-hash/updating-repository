using Aaris.World;

namespace Aaris.Tools;

public static class RouteTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("route planner preserves exact endpoints and never mutates source", Endpoints);
        yield return ("route planner and smoothing avoid continuous lake masks", Lake);
        yield return ("route edges detect thin obstacles between lattice nodes", ThinObstacle);
        yield return ("unreachable routes fail instead of emitting a partial path", Unreachable);
        yield return ("route search budgets fail explicitly", Budgets);
        yield return ("route planner rejects invalid options and ambiguous endpoints", InvalidRequests);
        yield return ("terrain weighted routes detour around steep hills", Hills);
        yield return ("route proposal ignores object and asset input ordering", Stable);
    }
    private static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    private static void Throws(Action action)
    {
        try { action(); }
        catch (Exception e) when (e is ArgumentException || e is InvalidOperationException) { return; }
        throw new Exception("Expected route rejection.");
    }
    private static (WorldSpec w, AssetRegistry a) Fixture()
        => (new WorldSpec { schemaVersion = 2, id = "RouteTest", grid = new GridSpec { originX = -64, originZ = -64, sizeX = 128, sizeZ = 128, cellSize = 64 }, terrain = new TerrainSpec { amplitude = 0 } },
            new AssetRegistry { schemaVersion = 2 });
    private static void Endpoints()
    {
        var (w, a) = Fixture(); string before = WorldFiles.Serialize(w);
        var p = RoutePlanner.Plan(w, a, new(-41, -17), new(43, 21), new());
        Assert(p.points[0].x == -41 && p.points[0].z == -17 && p.points[^1].x == 43 && p.points[^1].z == 21, "Endpoints were snapped silently.");
        Assert(p.weightedCost >= p.length - 1e-7 && before == WorldFiles.Serialize(w), "Cost lower bound or source immutability failed.");
    }
    private static void Lake()
    {
        var (w, a) = Fixture(); w.terrain.lakes = new[] { new LakeSpec { id = "Water", radiusX = 18, radiusZ = 14 } };
        var p = RoutePlanner.Plan(w, a, new(-44, 0), new(44, 0), new());
        for (int i = 1; i < p.points.Length; i++)
        {
            var l = w.terrain.lakes[0];
            Point2 Normalize(Point2 v) => new(v.x / l.radiusX, v.z / l.radiusZ);
            Assert(Geometry.PointSegmentDistance(new(), Normalize(p.points[i - 1]), Normalize(p.points[i])) > 1 + 2.5 / 14, "Shortcut crosses water or its clearance.");
        }
    }
    private static void AddWall(WorldSpec w, AssetRegistry a, double depth)
    {
        a.assets = new[] { new AssetSpec { id = "wall", width = 1, depth = depth, height = 2, clearance = 0 } };
        w.objects = new[] { new ObjectSpec { id = "ThinWall", asset = "wall", x = 4 } };
    }
    private static void ThinObstacle()
    {
        var (w, a) = Fixture(); AddWall(w, a, 32);
        var p = RoutePlanner.Plan(w, a, new(-40, 0), new(40, 0), new());
        var polygon = Geometry.Footprint(w.objects[0], a.assets[0]);
        for (int i = 1; i < p.points.Length; i++) Assert(Geometry.PolygonSegmentDistance(polygon, p.points[i - 1], p.points[i]) > 2.5, "Planner tunnelled through a thin obstacle.");
    }
    private static void Unreachable()
    {
        var (w, a) = Fixture(); AddWall(w, a, 124);
        Throws(() => RoutePlanner.Plan(w, a, new(-40, 0), new(40, 0), new()));
    }
    private static void Budgets()
    {
        var (w, a) = Fixture();
        Throws(() => RoutePlanner.Plan(w, a, new(-40, 0), new(40, 0), new() { maxNodes = 4 }));
        Throws(() => RoutePlanner.Plan(w, a, new(-40, 0), new(40, 0), new() { maxExpansions = 1 }));
    }
    private static void InvalidRequests()
    {
        var (w, a) = Fixture();
        Throws(() => RoutePlanner.Plan(w, a, new(), new(20, 20), new() { slopeWeight = -1 }));
        Throws(() => RoutePlanner.Plan(w, a, new(), new(20, 20), new() { spacing = double.NaN }));
        Throws(() => RoutePlanner.Plan(w, a, new(double.NaN, 0), new(20, 20), new()));
        Throws(() => RouteCommand.Propose(w, a, new() { expectedRevision = 0, start = new Point2(), end = new Point2(20, 20) }));
        Throws(() => RouteCommand.Propose(w, a, new() { expectedRevision = 1, end = new Point2(20, 20) }));
        AddWall(w, a, 32);
        Throws(() => RoutePlanner.Plan(w, a, new(4, 0), new(40, 0), new()));
    }
    private static void Hills()
    {
        var (w, a) = Fixture(); w.terrain.hills = new[] { new HillSpec { height = 40, radius = 18 } };
        var p = RoutePlanner.Plan(w, a, new(-48, 0), new(48, 0), new() { maxSlopeDegrees = 12 });
        Assert(p.points.Any(v => Math.Abs(v.z) > 16) && p.maxSampledSlope <= 12 + 1e-6, "Route did not avoid the steep hill.");
    }
    private static void Stable()
    {
        var (w, a) = Fixture(); AddWall(w, a, 32);
        a.assets = a.assets.Concat(new[] { new AssetSpec { id = "unused", width = 2 } }).ToArray();
        w.objects = w.objects.Concat(new[] { new ObjectSpec { id = "SideWall", asset = "wall", x = 40, z = 35 } }).ToArray();
        var first = RoutePlanner.Plan(w, a, new(-40, 0), new(40, 0), new());
        Array.Reverse(w.objects); Array.Reverse(a.assets);
        Assert(WorldFiles.Serialize(first) == WorldFiles.Serialize(RoutePlanner.Plan(w, a, new(-40, 0), new(40, 0), new())), "Route depends on source ordering.");
    }
}
