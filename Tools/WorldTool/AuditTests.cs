using Aaris.World;

namespace Aaris.Tools;

public static class AuditTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("stale input pulses expire across a stalled frame", InputExpiry);
        yield return ("input pulses consume once and cancellation removes them", InputOnce);
        yield return ("lost touch owners are pruned while remaining fingers stay held", LostTouch);
        yield return ("BVH ray hits nearest triangle within its range", Nearest);
        yield return ("BVH backface policy and axis-parallel rays are explicit", Faces);
        yield return ("BVH rejects malformed geometry and bounded build overflow", InvalidGeometry);
        yield return ("BVH traversal matches an independent brute-force ray oracle", BruteForce);
        yield return ("BVH tie ownership does not depend on source ordering", StableTies);
        yield return ("roof collision has a solid underside without changing visible triangles", RoofUnderside);
        yield return ("visibility review budgets fail before emitting a partial report", VisibilityBudgets);
    }
    private static void Assert(bool ok, string message = "Audit invariant failed.") { if (!ok) throw new Exception(message); }
    private static void Throws(Action action)
    { try { action(); } catch (Exception e) when (e is ArgumentException || e is InvalidOperationException) { return; } throw new Exception("Expected audit rejection."); }
    private static void InputExpiry()
    {
        var pulse = new InputPulse(); pulse.Request(1); Assert(!pulse.Consume(2, 0.15));
        pulse.Request(3); Assert(pulse.Consume(3.1, 0.15)); pulse.Request(4); Assert(!pulse.Consume(3, 0.15));
    }
    private static void InputOnce()
    {
        var pulse = new InputPulse(); pulse.Request(1); Assert(pulse.Consume(1.01, 0.15)); Assert(!pulse.Consume(1.02, 0.15));
        pulse.Request(2); pulse.Clear(); Assert(!pulse.Consume(2, 0.15)); Throws(() => pulse.Request(double.NaN));
    }
    private static void LostTouch()
    {
        var touch = new TouchOwnership(); touch.Begin(9, 0.9, 0.4); touch.Begin(5, 0.15, 0.2); touch.Begin(77, 0.5, 0.6);
        touch.Prune(new[] { 77, 5 }); Assert(!touch.Held(TouchRole.Fire) && touch.Held(TouchRole.Move) && touch.Held(TouchRole.Look));
        touch.Prune(Array.Empty<int>()); Assert(touch.Count == 0);
    }
    private static CollisionTriangle Plane(double y, string id) => new(new(-20, y, -20), new(0, y, 20), new(20, y, -20), id);
    private static void Nearest()
    {
        var tree = new CollisionBvh(new[] { Plane(0, "Low"), Plane(2, "High") });
        Assert(tree.Raycast(new(0, 5, 0), new(0, -10, 0), 8, out var hit) && hit.owner == "High" && Math.Abs(hit.distance - 3) < 1e-8);
        Assert(!tree.Raycast(new(0, 5, 0), new(0, -1, 0), 2.99, out _));
    }
    private static void Faces()
    {
        var tree = new CollisionBvh(new[] { Plane(0, "Floor") });
        Assert(!tree.Raycast(new(0, -1, 0), new(0, 1, 0), 5, out _));
        Assert(tree.Raycast(new(0, -1, 0), new(0, 1, 0), 5, out _, true));
        Assert(!tree.Raycast(new(30, 1, 0), new(0, -1, 0), 5, out _));
    }
    private static void InvalidGeometry()
    {
        Throws(() => new CollisionBvh(new[] { Plane(0, "A"), Plane(1, "B") }, 1));
        Throws(() => new CollisionBvh(new[] { new CollisionTriangle(new(), new(), new(), "Bad") }));
        var tree = new CollisionBvh(new[] { Plane(0, "A") });
        Throws(() => tree.Raycast(new(), new(), 10, out _)); Throws(() => tree.Raycast(new(double.NaN, 0, 0), new(0, 1, 0), 10, out _));
        Assert(!new CollisionBvh(Array.Empty<CollisionTriangle>()).Raycast(new(), new(0, 1, 0), 10, out _));
    }
    private static void BruteForce()
    {
        var random = new Random(1701); var tris = new List<CollisionTriangle>();
        for (int i = 0; i < 90; i++)
        {
            double x = random.NextDouble() * 30 - 15, z = random.NextDouble() * 30 - 15, y = random.NextDouble() * 6;
            tris.Add(new(new(x - 2, y, z - 2), new(x, y + 0.5, z + 2), new(x + 2, y, z - 2), "T" + i));
        }
        var tree = new CollisionBvh(tris);
        for (int i = 0; i < 250; i++)
        {
            var origin = new Point3(random.NextDouble() * 40 - 20, 12, random.NextDouble() * 40 - 20);
            var direction = new Point3(random.NextDouble() - 0.5, -1, random.NextDouble() - 0.5); direction = direction * (1 / direction.Length);
            double nearest = 40;
            foreach (var t in tris)
            {
                var normal = Point3.Cross(t.b - t.a, t.c - t.a); double dot = Point3.Dot(normal, direction);
                if (dot >= -1e-10) continue;
                double d = Point3.Dot(normal, t.a - origin) / dot; if (d <= 1e-6 || d > nearest) continue;
                var p = origin + direction * d;
                if (Point3.Dot(Point3.Cross(t.b - t.a, p - t.a), normal) >= -1e-7 && Point3.Dot(Point3.Cross(t.c - t.b, p - t.b), normal) >= -1e-7 && Point3.Dot(Point3.Cross(t.a - t.c, p - t.c), normal) >= -1e-7) nearest = d;
            }
            bool hit = tree.Raycast(origin, direction, 40, out var result);
            Assert(hit == (nearest < 40) && (!hit || Math.Abs(result.distance - nearest) < 1e-6), "BVH disagrees with brute force.");
        }
    }
    private static void StableTies()
    {
        var triangles = new[] { Plane(0, "Z"), Plane(0, "A") };
        var first = new CollisionBvh(triangles); Array.Reverse(triangles); var second = new CollisionBvh(triangles);
        Assert(first.Raycast(new(0, 5, 0), new(0, -1, 0), 10, out var a) && second.Raycast(new(0, 5, 0), new(0, -1, 0), 10, out var b) && a.owner == "A" && b.owner == "A");
    }
    private static void RoofUnderside()
    {
        var assets = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath).assets.Where(a => a.previewShape == "building");
        foreach (var asset in assets)
        {
            var model = ProceduralArt.Create(asset, 0);
            var tree = new CollisionBvh(CollisionBvh.MeshTriangles(model.collision, asset.id, v => new(v.x, v.y, v.z)));
            double body = asset.height - Math.Min(asset.height * 0.25, 2.4);
            Assert(tree.Raycast(new(asset.width * 0.2, body + 0.02, 0), new(0, 1, 0), 4, out var hit) && hit.distance < 3, asset.id + " has no front-facing roof underside.");
            Assert(model.TriangleCount == asset.triangles, "Visible art changed during collision-only roof fix.");
        }
    }
    private static void VisibilityBudgets()
    {
        var w = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath); var a = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
        Throws(() => VisibilityReview.Analyze(w, a, new() { maxSamples = 1 }));
        Throws(() => VisibilityReview.Analyze(w, a, new() { range = double.NaN }));
        string before = WorldFiles.Serialize(w);
        Throws(() => CoverRefiner.Propose(w, a, new() { expectedRevision = w.revision - 1 }));
        Throws(() => CoverRefiner.Propose(w, a, new() { expectedRevision = w.revision, maxPairs = 99 }));
        Assert(before == WorldFiles.Serialize(w), "Rejected cover request mutated source.");
    }
}
