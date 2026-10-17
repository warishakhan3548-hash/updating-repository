using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Aaris.World;

namespace Aaris.Tools;

public sealed class VisibilityOptions
{
    public double spacing = 8, range = 120, eyeHeight = 1.6;
    public int directions = 24, maxSamples = 2048;
}
public sealed class VisibilitySample
{
    public string route;
    public double x, z, openFraction, nearbyBlockFraction, meanFirstHit;
    public bool exposed;
}
public sealed class VisibilityRoute
{
    public string id;
    public int samples;
    public double meanOpenFraction, longestExposedRun;
}
public sealed class VisibilityReport
{
    public int triangles, rayCount;
    public VisibilityRoute[] routes;
    public VisibilitySample[] samples;
}

public static class VisibilityReview
{
    public static VisibilityReport Analyze(WorldSpec w, AssetRegistry registry, VisibilityOptions options)
    {
        if (options == null || !WorldValidator.Finite(options.spacing, options.range, options.eyeHeight) || options.spacing < 4 || options.spacing > 32 ||
            options.range < 20 || options.range > 300 || options.eyeHeight < 0.6 || options.eyeHeight > 2 || options.directions < 8 || options.directions > 64 ||
            options.maxSamples < 1 || options.maxSamples > 4096) throw new ArgumentException("Visibility review needs bounded sampling options.");
        var errors = WorldValidator.Validate(w, registry); if (errors.Count != 0) throw new InvalidOperationException("Invalid world: " + errors[0]);
        var points = w.routes.OrderBy(r => r.id, StringComparer.Ordinal).Select(r => new { route = r.id, points = WorldDesign.SampleRoute(r, options.spacing).ToArray() }).ToArray();
        int count = points.Sum(r => r.points.Length);
        if (count > options.maxSamples || (long)count * options.directions > 65536) throw new InvalidOperationException("Visibility sample/ray budget exceeded; review smaller regions.");
        var bvh = CollisionBvh.FromWorld(w, registry); var terrain = new TerrainSampler(w); var samples = new List<VisibilitySample>(); var routes = new List<VisibilityRoute>();
        var g = w.grid;
        foreach (var route in points)
        {
            double run = 0; VisibilitySample previous = null;
            var rr = new VisibilityRoute { id = route.route };
            foreach (var p in route.points)
            {
                var origin = new Point3(p.x, terrain.Height(p.x, p.z) + options.eyeHeight, p.z);
                int open = 0, near = 0, rays = 0; double firstHit = 0;
                for (int i = 0; i < options.directions; i++)
                {
                    double angle = i * 2 * Math.PI / options.directions, dx = Math.Cos(angle), dz = Math.Sin(angle), range = options.range;
                    if (dx > 1e-9) range = Math.Min(range, (g.originX + g.sizeX - 0.01 - p.x) / dx);
                    if (dx < -1e-9) range = Math.Min(range, (g.originX + 0.01 - p.x) / dx);
                    if (dz > 1e-9) range = Math.Min(range, (g.originZ + g.sizeZ - 0.01 - p.z) / dz);
                    if (dz < -1e-9) range = Math.Min(range, (g.originZ + 0.01 - p.z) / dz);
                    if (range < 5) continue;
                    double x = p.x + dx * range, z = p.z + dz * range;
                    var direction = new Point3(x, terrain.Height(x, z) + options.eyeHeight, z) - origin;
                    bool hit = bvh.Raycast(origin, direction, direction.Length, out var contact);
                    if (!hit) open++; else if (contact.distance <= 20) near++;
                    firstHit += hit ? contact.distance : direction.Length; rays++;
                }
                var sample = new VisibilitySample { route = route.route, x = p.x, z = p.z,
                    openFraction = rays == 0 ? 0 : (double)open / rays, nearbyBlockFraction = rays == 0 ? 0 : (double)near / rays, meanFirstHit = rays == 0 ? 0 : firstHit / rays };
                sample.exposed = sample.openFraction >= 0.75 && sample.nearbyBlockFraction <= 0.125;
                run = sample.exposed && previous != null && previous.exposed ? run + WorldDesign.Distance(new Point2(previous.x, previous.z), p) : 0;
                rr.longestExposedRun = Math.Max(rr.longestExposedRun, run); rr.meanOpenFraction += sample.openFraction;
                samples.Add(sample); previous = sample;
            }
            rr.samples = route.points.Length; if (rr.samples > 0) rr.meanOpenFraction /= rr.samples; routes.Add(rr);
        }
        return new VisibilityReport { triangles = bvh.TriangleCount, rayCount = count * options.directions, routes = routes.ToArray(), samples = samples.ToArray() };
    }

    public static void Write(WorldSpec world, AssetRegistry registry, string directory)
    {
        var options = new VisibilityOptions(); var report = Analyze(world, registry, options); Directory.CreateDirectory(directory);
        string[] inputs = { WorldFiles.WorldPath, WorldFiles.RegistryPath, "Assets/Aaris/World/Core/ProceduralArt.cs", "Assets/Aaris/World/Core/WorldGeometry.cs", "Assets/Aaris/World/Core/TerrainSampler.cs", "Assets/Aaris/World/Core/CollisionBvh.cs", "Tools/WorldTool/VisibilityReview.cs" };
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var path in inputs.OrderBy(p => p, StringComparer.Ordinal)) { hash.AppendData(Encoding.UTF8.GetBytes(path + "\0")); byte[] bytes = File.ReadAllBytes(path); hash.AppendData(BitConverter.GetBytes((long)bytes.Length)); hash.AppendData(bytes); }
        string fingerprint = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        File.WriteAllText(Path.Combine(directory, "visibility.json"), WorldFiles.Serialize(new {
            world = world.id, world.revision, worldSourceSha256 = WorldFiles.Fingerprint(), analysisInputsSha256 = fingerprint, options, report,
            scope = "Static source collision triangles; front-face rays, terrain-relative standing eyes, fixed directions. Not renderer occlusion culling, measured combat balance, a complete visibility field, runtime PhysX or a multiplayer server. Water, foliage canopy, dynamic actors and external prefabs do not provide modeled cover.",
            warningRule = "Review flag only: >=75% directions unblocked, <=12.5% blocked within 20m. Project heuristic, not a proprietary game's constants or an automatic placement approval."
        }));
        double scale = 900 / Math.Max(world.grid.sizeX, world.grid.sizeZ);
        string N(double x) => x.ToString("0.###", CultureInfo.InvariantCulture);
        var overlay = new StringBuilder();
        foreach (var p in report.samples)
        {
            int red = (int)(70 + p.openFraction * 180), green = (int)(190 - p.openFraction * 130);
            overlay.Append("<circle cx=\"" + N(64 + (p.x - world.grid.originX) * scale) + "\" cy=\"" + N(64 + (world.grid.originZ + world.grid.sizeZ - p.z) * scale) + "\" r=\"3.2\" fill=\"rgb(" + red + "," + green + ",65)\" stroke=\"#18202b\" stroke-width=\"0.5\"/>");
        }
        overlay.Append("<text x=\"64\" y=\"1054\" font-size=\"11\" font-family=\"sans-serif\" fill=\"#e4edf2\">STATIC STANDING VISIBILITY / GREEN: LOWER OPEN FRACTION / RED: HIGHER / SAMPLED REVIEW</text>");
        File.WriteAllText(Path.Combine(directory, "visibility.svg"), ReviewWriter.Svg(world, registry).Replace("</svg>", overlay + "</svg>"));
        Console.WriteLine($"Visibility review: {report.triangles} collision triangles, {report.samples.Length} samples, up to {report.rayCount} rays. Flags are review guidance; source unchanged.");
        foreach (var route in report.routes) Console.WriteLine($"{route.id}: mean open directions {route.meanOpenFraction:P0}, longest flagged run {route.longestExposedRun:0.0} m.");
    }
}
