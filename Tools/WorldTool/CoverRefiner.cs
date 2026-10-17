using System.Text.Json;
using Aaris.World;

namespace Aaris.Tools;

public sealed class CoverRefineRequest
{
    public int expectedRevision;
    public int maxPairs = 6;
    public double targetLongestRun = 80;
}
public static class CoverRefiner
{
    public static (WorldSpec world, VisibilityReport before, VisibilityReport after) Propose(WorldSpec original, AssetRegistry assets, CoverRefineRequest request, SandboxSpec sandbox = null)
    {
        if (request == null || request.expectedRevision != original.revision) throw new InvalidOperationException("Stale cover request; read the current revision.");
        if (request.maxPairs < 1 || request.maxPairs > 8 || !WorldValidator.Finite(request.targetLongestRun) || request.targetLongestRun < 40 || request.targetLongestRun > 150)
            throw new ArgumentException("Use 1–8 cover pairs and a finite 40–150m review target.");
        var rock = assets.assets.SingleOrDefault(a => a.id == "ridge_boulder" && a.archetype == "boulder") ?? throw new InvalidOperationException("No registered procedural ridge boulder.");
        var w = JsonSerializer.Deserialize<WorldSpec>(WorldFiles.Serialize(original), WorldFiles.Json);
        var before = VisibilityReview.Analyze(w, assets, new()); var current = before;
        int added = 0;
        for (int pass = 0; pass < request.maxPairs; pass++)
        {
            var route = current.routes.OrderByDescending(r => r.longestExposedRun).ThenBy(r => r.id, StringComparer.Ordinal).FirstOrDefault();
            if (route == null || route.longestExposedRun <= request.targetLongestRun) break;
            var samples = current.samples.Where(s => s.route == route.id).ToArray();
            int start = 0, bestStart = 0, bestEnd = 0; double length = 0, best = 0;
            for (int i = 0; i < samples.Length; i++)
            {
                if (!samples[i].exposed) { start = i + 1; length = 0; continue; }
                if (i > start) length += WorldDesign.Distance(new(samples[i - 1].x, samples[i - 1].z), new(samples[i].x, samples[i].z));
                if (length > best) { best = length; bestStart = start; bestEnd = i; }
            }
            int midpoint = (bestStart + bestEnd) / 2;
            var centre = samples[midpoint]; var p = samples[Math.Max(0, midpoint - 1)]; var q = samples[Math.Min(samples.Length - 1, midpoint + 1)];
            double dx = q.x - p.x, dz = q.z - p.z, distance = Math.Sqrt(dx * dx + dz * dz);
            if (distance < 0.001) break;
            bool accepted = false;
            foreach (var variant in new[] { (13d,0d), (16d,0d), (19d,0d), (13d,12d), (16d,12d), (19d,12d), (13d,-12d), (16d,-12d), (19d,-12d) })
            {
                double offset = variant.Item1, along = variant.Item2;
                var ids = new HashSet<string>(w.objects.Select(o => o.id), StringComparer.Ordinal);
                string Id(int serial) { string id; do { id = "ROCK_TACTICAL_" + (serial++).ToString("D3"); } while (ids.Contains(id)); ids.Add(id); return id; }
                var pair = new[] { -1, 1 }.Select((side, index) => new ObjectSpec {
                    id = Id(added + index + 1), asset = rock.id,
                    x = Math.Round(centre.x - dz / distance * offset * side + dx / distance * (side * 2 + along), 3),
                    z = Math.Round(centre.z + dx / distance * offset * side + dz / distance * (side * 2 + along), 3),
                    scale = 1.4, yaw = (w.seed + pass * 137 + index * 59) % 360
                }).ToArray();
                var previous = w.objects; w.objects = previous.Concat(pair).ToArray();
                var diagnostics = WorldValidator.Validate(w, assets);
                if (diagnostics.Count != 0 || (sandbox != null && SandboxValidator.Validate(sandbox, w, assets).Count != 0)) { w.objects = previous; continue; }
                var report = VisibilityReview.Analyze(w, assets, new());
                if (report.routes.Single(r => r.id == route.id).longestExposedRun >= route.longestExposedRun - 1 || report.routes.Max(r => r.longestExposedRun) > current.routes.Max(r => r.longestExposedRun) + 0.01)
                { w.objects = previous; continue; }
                current = report; added += 2; accepted = true; break;
            }
            if (!accepted) break; // Leave unresolved constraints visible; never force an invalid placement.
        }
        if (added > 0) w.revision = checked(w.revision + 1);
        return (w, before, current);
    }
    public static void Write(WorldSpec original, AssetRegistry assets, CoverRefineRequest request, string directory)
    {
        var sandbox = WorldFiles.Read<SandboxSpec>("Assets/GameData/World/sandbox.json");
        var result = Propose(original, assets, request, sandbox); Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "world.json"), WorldFiles.Serialize(result.world));
        File.WriteAllText(Path.Combine(directory, "comparison.json"), WorldFiles.Serialize(new {
            sourceSha256 = WorldFiles.Fingerprint(), request, sourceRevision = original.revision, proposedRevision = result.world.revision,
            addedObjects = result.world.objects.Length - original.objects.Length, before = result.before.routes, after = result.after.routes,
            note = "Reviewed proposal only. Full source placement/budget validation and sampled static visibility improvement required for acceptance. No claim of final combat balance. Original source unchanged."
        }));
        Console.WriteLine($"Cover proposal: {result.world.objects.Length - original.objects.Length} rocks; max flagged run {result.before.routes.Max(r => r.longestExposedRun):0.0} -> {result.after.routes.Max(r => r.longestExposedRun):0.0} m. Source unchanged.");
    }
}
