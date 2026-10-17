using System.Text.Json;
using Aaris.World;

namespace Aaris.Tools;

// No NuGet test runner: these exercise the exact C# sources also compiled by Unity.
// A failed assertion returns nonzero in CI and in constrained, phone-only workflows.
public static class SelfTests
{
    public static int Run()
    {
        var tests = new (string name, Action body)[]
        {
            ("sample world compiles", Sample),
            ("canonical plan ignores object input ordering", StableOrder),
            ("terrain seed changes terrain", Seed),
            ("terrain interpolation matches rendered triangles", Triangles),
            ("terrain cell seams are continuous", Seams),
            ("negative coordinates and world max edge", NegativeCoordinates),
            ("cross-cell footprints have one owner and multiple references", CrossCell),
            ("rotated footprint overlap is rejected", RotatedOverlap),
            ("separated rotated footprints are accepted", RotatedSeparation),
            ("clearance spanning adjacent cells is enforced", CrossCellClearance),
            ("road crossing through footprint is rejected", RoadCrossing),
            ("degenerate and collinear segment distances", SegmentDistances),
            ("road endpoint clearance is enforced", RoadEndpoint),
            ("rotated world boundary is rejected", Bounds),
            ("duplicate IDs across types are rejected", DuplicateIds),
            ("NaN transforms rejected", NonFinite),
            ("null nested arrays return diagnostics", NullArrays),
            ("unknown assets rejected", UnknownAssets),
            ("fractional cell and terrain grids rejected", BadGrid),
            ("slope limits enforced", Slope),
            ("foundation height variation enforced", Relief),
            ("cell budgets include cross-cell references", Budgets),
            ("shared asset textures counted once per cell", SharedTextures),
            ("valid move updates revision and preserves source", ValidMove),
            ("invalid move leaves source intact", InvalidMove),
            ("stale moves rejected", StaleMove),
            ("marker move resolves coordinates", MarkerMove),
            ("missing marker does not default to origin", UnknownMarker),
            ("omitted target cannot silently move to origin", MissingTarget),
            ("marker and explicit zero coordinates are ambiguous", AmbiguousTarget),
            ("streaming uses distance to cell bounds", StreamingBounds),
            ("streaming hysteresis retains previously loaded cells", Hysteresis),
            ("streaming capacity fails instead of dropping collision", StreamingCapacity),
            ("production-art gate rejects blockouts", ProductionGate),
            ("registry path traversal rejected", PathTraversal),
            ("strict JSON rejects typos and duplicate keys", StrictJson),
            ("atomic file replacement leaves no temporary file", AtomicReplacement),
            ("schematic preview escapes user text", Escaping)
        }.Concat(UpgradeTests.Cases()).Concat(RouteTests.Cases()).Concat(GameplayTests.Cases()).Concat(AuditTests.Cases()).Concat(TacticalTests.Cases()).Concat(LootTests.Cases()).Concat(StreamingTransitionTests.Cases()).ToArray();
        int failed = 0;
        foreach (var test in tests)
        {
            try { test.body(); Console.WriteLine("PASS " + test.name); }
            catch (Exception e) { failed++; Console.Error.WriteLine("FAIL " + test.name + ": " + e.Message); }
        }
        Console.WriteLine($"{tests.Length - failed}/{tests.Length} passed.");
        return failed == 0 ? 0 : 1;
    }

    private static void Assert(bool ok, string message = "Assertion failed") { if (!ok) throw new Exception(message); }
    private static void Near(double a, double b, double tolerance = 1e-8) => Assert(Math.Abs(a - b) <= tolerance, $"{a} != {b}");
    private static void Throws(Action action)
    {
        try { action(); } catch (Exception e) when (e is InvalidOperationException || e is ArgumentException || e is InvalidDataException || e is JsonException) { return; }
        throw new Exception("Expected failure.");
    }
    private static (WorldSpec w, AssetRegistry a) Fixture()
    {
        return (new WorldSpec { id = "TestWorld", terrain = new TerrainSpec { amplitude = 0 },
            objects = new[] { new ObjectSpec { id = "House_A", asset = "house", x = -20, z = -20 } } },
            new AssetRegistry { assets = new[] { new AssetSpec { id = "house", width = 10, depth = 10, clearance = 0 } } });
    }
    private static void Has(WorldSpec w, AssetRegistry a, string code)
        => Assert(WorldValidator.Validate(w, a).Any(e => e.code == code), "Missing diagnostic " + code);
    private static void Good(WorldSpec w, AssetRegistry a)
    { var e = WorldValidator.Validate(w, a); Assert(e.Count == 0, string.Join("\n", e)); }

    private static void Sample()
    {
        var w = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath); var a = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
        Good(w, a); var p = WorldCompiler.Compile(w, a);
        Assert(p.cells.Length == 64 && p.objects.Length > 20);
        Assert(p.cells.Sum(c => c.ownedObjects.Length) == w.objects.Length);
        Assert(WorldFiles.Serialize(p) == WorldFiles.Serialize(WorldCompiler.Compile(w, a)));
    }
    private static void StableOrder()
    {
        var w = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath); var a = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
        string first = WorldFiles.Serialize(WorldCompiler.Compile(w, a));
        Array.Reverse(w.objects); Array.Reverse(a.assets);
        Assert(first == WorldFiles.Serialize(WorldCompiler.Compile(w, a)));
    }
    private static void Seed()
    {
        var (w, _) = Fixture(); w.terrain.amplitude = 20;
        double first = new TerrainSampler(w).Height(37, 62); w.seed++;
        Assert(Math.Abs(first - new TerrainSampler(w).Height(37, 62)) > 0.001);
    }
    private static void Triangles()
    {
        var (w, _) = Fixture(); w.terrain.amplitude = 20; var t = new TerrainSampler(w);
        double x = 0, z = 0, step = w.terrain.gridSpacing;
        double a = t.VertexHeight(x, z), b = t.VertexHeight(x + step, z), c = t.VertexHeight(x, z + step), d = t.VertexHeight(x + step, z + step);
        Near(t.Height(2, 2), a + 0.25 * (b - a) + 0.25 * (c - a));
        Near(t.Height(6, 6), d + 0.25 * (c - d) + 0.25 * (b - d));
    }
    private static void Seams()
    {
        var (w, _) = Fixture(); w.terrain.amplitude = 20; var t = new TerrainSampler(w);
        foreach (double x in new[] { -384d, -128d, 0d, 128d, 384d })
            for (int z = -500; z < 500; z += 29) Near(t.Height(x - 0.00001, z), t.Height(x + 0.00001, z), 0.0001);
    }
    private static void NegativeCoordinates()
    {
        var g = new GridSpec();
        Assert(WorldCompiler.CellAt(g, -0.01, -0.01).Equals(new CellKey(3, 3)));
        Assert(WorldCompiler.CellAt(g, 0, 0).Equals(new CellKey(4, 4)));
        Assert(WorldCompiler.CellAt(g, 512, 512).Equals(new CellKey(7, 7)));
    }
    private static void CrossCell()
    {
        var (w, a) = Fixture(); w.objects[0].x = 0; w.objects[0].z = 0;
        var p = WorldCompiler.Compile(w, a);
        Assert(p.cells.Count(c => c.ownedObjects.Contains("House_A")) == 1);
        Assert(p.cells.Count(c => c.references.Contains("House_A")) == 4);
    }
    private static void RotatedOverlap()
    {
        var (w, a) = Fixture();
        w.objects = new[] { new ObjectSpec { id = "A", asset = "house", yaw = 45 }, new ObjectSpec { id = "B", asset = "house", x = 10, yaw = -45 } };
        Has(w, a, "OVERLAP");
    }
    private static void RotatedSeparation()
    {
        var (w, a) = Fixture(); a.assets[0].width = 20; a.assets[0].depth = 2;
        w.objects = new[] { new ObjectSpec { id = "A", asset = "house", yaw = 45 }, new ObjectSpec { id = "B", asset = "house", x = 5, z = 5, yaw = 45 } };
        Good(w, a);
    }
    private static void CrossCellClearance()
    {
        var (w, a) = Fixture(); a.assets[0].clearance = 4;
        w.objects = new[] { new ObjectSpec { id = "A", asset = "house", x = -6 }, new ObjectSpec { id = "B", asset = "house", x = 6 } };
        Has(w, a, "OVERLAP");
    }
    private static void RoadCrossing()
    {
        var (w, a) = Fixture(); w.objects[0].x = w.objects[0].z = 0;
        w.roads = new[] { new RoadSpec { id = "Road", points = new[] { new Point2(-100, 0), new Point2(100, 0) }, width = 2, clearance = 0 } };
        Has(w, a, "ROAD_CLEARANCE");
    }
    private static void SegmentDistances()
    {
        Near(Geometry.SegmentDistance(new(0, 0), new(10, 0), new(4, 0), new(12, 0)), 0);
        Near(Geometry.SegmentDistance(new(0, 0), new(10, 0), new(12, 0), new(14, 0)), 2);
        Near(Geometry.SegmentDistance(new(0, 0), new(0, 0), new(3, 4), new(3, 4)), 5);
    }
    private static void RoadEndpoint()
    {
        var (w, a) = Fixture(); w.objects[0].x = 9; w.objects[0].z = 0;
        w.roads = new[] { new RoadSpec { id = "Road", width = 4, clearance = 3, points = new[] { new Point2(-20, 0), new Point2(0, 0) } } };
        Has(w, a, "ROAD_CLEARANCE");
    }
    private static void Bounds()
    {
        var (w, a) = Fixture(); w.objects[0].x = 507; w.objects[0].yaw = 45;
        Has(w, a, "OUT_OF_BOUNDS");
    }
    private static void DuplicateIds()
    {
        var (w, a) = Fixture(); w.markers = new[] { new MarkerSpec { id = "House_A" } };
        Has(w, a, "DUPLICATE_ID");
    }
    private static void NonFinite()
    {
        var (w, a) = Fixture(); w.objects[0].yaw = double.NaN; Has(w, a, "TRANSFORM");
        w.objects[0].yaw = 0; w.grid.cellSize = double.PositiveInfinity; Has(w, a, "GRID");
    }
    private static void NullArrays()
    {
        var (w, a) = Fixture(); w.terrain.pads = null; Has(w, a, "TERRAIN");
        w.terrain.pads = Array.Empty<TerrainPad>(); w.objects = null; Has(w, a, "MISSING_SECTION");
    }
    private static void UnknownAssets()
    { var (w, a) = Fixture(); w.objects[0].asset = "missing"; Has(w, a, "UNKNOWN_ASSET"); }
    private static void BadGrid()
    {
        var (w, a) = Fixture(); w.grid.cellSize = 127; Has(w, a, "GRID");
        w.grid.cellSize = 128; w.terrain.gridSpacing = 7; Has(w, a, "TERRAIN");
    }
    private static void Slope()
    {
        var (w, a) = Fixture(); w.terrain.amplitude = 40; a.assets[0].maxSlopeDegrees = 0; a.assets[0].maxRelief = 100;
        Has(w, a, "SLOPE");
    }
    private static void Relief()
    {
        var (w, a) = Fixture(); w.terrain.amplitude = 40; a.assets[0].maxSlopeDegrees = 80; a.assets[0].maxRelief = 0;
        Has(w, a, "RELIEF");
    }
    private static void Budgets()
    {
        var (w, a) = Fixture(); w.objects[0].x = w.objects[0].z = 0;
        w.budget.triangles = 600;
        var errors = WorldValidator.Validate(w, a).Where(e => e.code == "CELL_BUDGET").ToArray();
        Assert(errors.Length == 4, "Cross-cell reference costs were not counted in every cell.");
    }
    private static void SharedTextures()
    {
        var (w, a) = Fixture(); a.assets[0].textureKiB = 64;
        w.objects = new[] { new ObjectSpec { id = "A", asset = "house", x = -80, z = -80 }, new ObjectSpec { id = "B", asset = "house", x = -40, z = -40 } };
        var plan = WorldCompiler.Compile(w, a);
        Assert(plan.cells.Single(c => c.key.Equals(new CellKey(3, 3))).cost.textureKiB == 64);
    }
    private static void ValidMove()
    {
        var (w, a) = Fixture(); string before = WorldFiles.Serialize(w);
        var updated = WorldEditor.Move(w, a, new MoveRequest { objectId = "House_A", expectedRevision = 1, x = 200, z = 200, yaw = 90 });
        Assert(updated.revision == 2 && updated.objects[0].x == 200 && WorldFiles.Serialize(w) == before);
        Assert(WorldCompiler.Compile(updated, a).objects[0].owner.Equals(new CellKey(5, 5)));
    }
    private static void InvalidMove()
    {
        var (w, a) = Fixture(); string before = WorldFiles.Serialize(w);
        Throws(() => WorldEditor.Move(w, a, new MoveRequest { objectId = "House_A", expectedRevision = 1, x = 512, z = 512, yaw = 0 }));
        Assert(before == WorldFiles.Serialize(w));
    }
    private static void StaleMove()
    { var (w, a) = Fixture(); Throws(() => WorldEditor.Move(w, a, new MoveRequest { objectId = "House_A", expectedRevision = 0 })); }
    private static void MarkerMove()
    {
        var (w, a) = Fixture(); w.markers = new[] { new MarkerSpec { id = "M001", x = 100, z = 90, yaw = 42 } };
        var moved = WorldEditor.Move(w, a, new MoveRequest { objectId = "House_A", expectedRevision = 1, markerId = "M001" });
        Near(moved.objects[0].x, 100); Near(moved.objects[0].z, 90); Near(moved.objects[0].yaw, 42);
    }
    private static void UnknownMarker()
    { var (w, a) = Fixture(); Throws(() => WorldEditor.Move(w, a, new MoveRequest { objectId = "House_A", expectedRevision = 1, markerId = "Missing" })); }
    private static void MissingTarget()
    {
        var (w, a) = Fixture(); string before = WorldFiles.Serialize(w);
        Throws(() => WorldEditor.Move(w, a, new MoveRequest { objectId = "House_A", expectedRevision = 1 }));
        Assert(before == WorldFiles.Serialize(w));
    }
    private static void AmbiguousTarget()
    {
        var (w, a) = Fixture(); w.markers = new[] { new MarkerSpec { id = "M001", x = 100, z = 100 } };
        Throws(() => WorldEditor.Move(w, a, new MoveRequest { objectId = "House_A", expectedRevision = 1, markerId = "M001", x = 0, z = 0, yaw = 0 }));
    }
    private static void StreamingBounds()
    {
        var (w, _) = Fixture(); w.streaming.loadRadius = 2; w.streaming.unloadRadius = 3;
        var p = StreamingPlanner.Desired(w, 1, 1, Array.Empty<CellKey>());
        Assert(p.Length == 4 && p.Contains(new CellKey(3, 3)), "Cell corners should load even if their centres are distant.");
    }
    private static void Hysteresis()
    {
        var (w, _) = Fixture(); w.streaming.loadRadius = 10; w.streaming.unloadRadius = 30;
        var key = new CellKey(3, 3);
        Assert(!StreamingPlanner.Desired(w, 20, -50, Array.Empty<CellKey>()).Contains(key));
        Assert(StreamingPlanner.Desired(w, 20, -50, new[] { key }).Contains(key));
        Assert(!StreamingPlanner.Desired(w, 31, -50, new[] { key }).Contains(key));
    }
    private static void StreamingCapacity()
    { var (w, _) = Fixture(); w.streaming.maxResidentCells = 1; Throws(() => StreamingPlanner.Desired(w, 0, 0, Array.Empty<CellKey>())); }
    private static void ProductionGate()
    { var (w, a) = Fixture(); Assert(WorldValidator.Validate(w, a, true).Any(e => e.code == "PRODUCTION_ART")); }
    private static void PathTraversal()
    { var (w, a) = Fixture(); a.assets[0].prefabPath = "Assets/Art/../Secrets/secret.prefab"; Has(w, a, "ASSET_PATH"); }
    private static void StrictJson()
    {
        string path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, "{\"objectId\":\"A\",\"xx\":1}"); Throws(() => WorldFiles.Read<MoveRequest>(path));
            File.WriteAllText(path, "{\"x\":1,\"x\":2}"); Throws(() => WorldFiles.Read<MoveRequest>(path));
        }
        finally { File.Delete(path); }
    }
    private static void AtomicReplacement()
    {
        string dir = Path.Combine(Path.GetTempPath(), "aaris-test-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(dir);
        try
        {
            string path = Path.Combine(dir, "world.json"); File.WriteAllText(path, "old");
            WorldFiles.AtomicWrite(path, "new");
            Assert(File.ReadAllText(path) == "new" && Directory.GetFiles(dir).Length == 1);
        }
        finally { Directory.Delete(dir, true); }
    }
    private static void Escaping()
    {
        var (w, a) = Fixture(); w.landmarks = new[] { new LandmarkSpec { id = "Town", name = "<script>alert(1)</script>" } };
        string svg = ReviewWriter.Svg(w, a);
        Assert(!svg.Contains("<script>") && svg.Contains("&lt;script&gt;"));
    }
}
