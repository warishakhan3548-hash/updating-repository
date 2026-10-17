using System;
using System.Collections.Generic;
using System.Linq;
using Aaris.World;

namespace Aaris.Tools;

public static class StreamingTransitionTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("streaming owners load once before their references", OwnersFirst);
        yield return ("streaming dependency capacity fails closed", DependencyCapacity);
        yield return ("streaming velocity prioritizes ahead on equal distance", AheadTie);
        yield return ("streaming resident inputs are deduplicated and releases are stable", ResidentAndRelease);
        yield return ("streaming stale manifests and invalid positions are rejected", InvalidInputs);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static (WorldSpec world, WorldPlan plan) Fixture()
    {
        var w = new WorldSpec
        {
            id = "streaming-test", revision = 3, seed = 41,
            grid = new GridSpec { originX = 0, originZ = 0, sizeX = 192, sizeZ = 64, cellSize = 64 },
            streaming = new StreamingSpec { loadRadius = 8, unloadRadius = 24, maxResidentCells = 3 }
        };
        var p = new WorldPlan
        {
            worldId = w.id, revision = w.revision, seed = w.seed,
            cells = new[]
            {
                new CellPlan { key = new CellKey(0, 0), ownedObjects = new[] { "bridge" }, references = Array.Empty<string>() },
                new CellPlan { key = new CellKey(1, 0), ownedObjects = Array.Empty<string>(), references = Array.Empty<string>() },
                new CellPlan { key = new CellKey(2, 0), ownedObjects = Array.Empty<string>(), references = new[] { "bridge", "bridge" } }
            },
            objects = new[] { new ResolvedObject { id = "bridge", asset = "bridge", owner = new CellKey(0, 0) } }
        };
        return (w, p);
    }

    private static void OwnersFirst()
    {
        var (w, p) = Fixture();
        var step = StreamingTransitionPlanner.Plan(w, p, 144, 32, 0, 0, Array.Empty<CellKey>());
        Check(step.requiredCells.SequenceEqual(new[] { new CellKey(0, 0), new CellKey(2, 0) }), "Owner and referenced terrain must be present.");
        Check(step.loadOrder.SequenceEqual(new[] { new CellKey(0, 0), new CellKey(2, 0) }), "Owner must load first, but exactly once.");
        Check(step.referencedObjects.SequenceEqual(new[] { "bridge" }), "A multi-cell object must have one identity.");
        var stable = StreamingTransitionPlanner.Plan(w, p, 144, 32, 0, 0, new[] { new CellKey(0, 0), new CellKey(2, 0) });
        Check(stable.loadOrder.Length == 0 && stable.releaseOrder.Length == 0, "Already resident dependencies should stay loaded.");
    }

    private static void DependencyCapacity()
    {
        var (w, p) = Fixture();
        w.streaming.maxResidentCells = 1;
        bool failed = false;
        try { StreamingTransitionPlanner.Plan(w, p, 144, 32, 0, 0, Array.Empty<CellKey>()); }
        catch (InvalidOperationException) { failed = true; }
        Check(failed, "Missing a mandatory owner must never be hidden by a capacity cap.");
    }

    private static void AheadTie()
    {
        var (w, p) = Fixture();
        p.cells[2].references = Array.Empty<string>();
        w.streaming.loadRadius = 64;
        var step = StreamingTransitionPlanner.Plan(w, p, 96, 32, 100, 0, Array.Empty<CellKey>());
        Check(step.loadOrder.SequenceEqual(new[] { new CellKey(1, 0), new CellKey(2, 0), new CellKey(0, 0) }),
            "Near terrain should load first; equal-distance cells should favor the direction of travel.");
    }

    private static void ResidentAndRelease()
    {
        var (w, p) = Fixture();
        p.cells[2].references = Array.Empty<string>();
        var step = StreamingTransitionPlanner.Plan(w, p, 170, 32, 0, 0,
            new[] { new CellKey(0, 0), new CellKey(1, 0), new CellKey(1, 0), new CellKey(2, 0) });
        Check(step.loadOrder.Length == 0, "The near cell is resident.");
        Check(step.releaseOrder.SequenceEqual(new[] { new CellKey(0, 0), new CellKey(1, 0) }), "Release farthest cell first without duplicating entries.");
    }

    private static void InvalidInputs()
    {
        var (w, p) = Fixture();
        bool stale = false, outside = false, infinite = false, orphan = false;
        p.revision++;
        try { StreamingTransitionPlanner.Plan(w, p, 144, 32, 0, 0, null); }
        catch (InvalidOperationException) { stale = true; }
        p.revision--;
        try { StreamingTransitionPlanner.Plan(w, p, -1, 32, 0, 0, null); }
        catch (ArgumentException) { outside = true; }
        try { StreamingTransitionPlanner.Plan(w, p, 144, 32, double.PositiveInfinity, 0, null); }
        catch (ArgumentException) { infinite = true; }
        p.objects = Array.Empty<ResolvedObject>();
        try { StreamingTransitionPlanner.Plan(w, p, 144, 32, 0, 0, null); }
        catch (InvalidOperationException) { orphan = true; }
        Check(stale && outside && infinite && orphan, "Invalid streaming state must reject before any scene mutation.");
    }
}
