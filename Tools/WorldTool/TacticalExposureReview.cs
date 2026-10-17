using System.Globalization;
using System.Security;
using System.Text;
using Aaris.World;

namespace Aaris.Tools;

// Offline world-authoring evidence, not player visibility, NavMesh or measured FPS.
public sealed class TacticalExposureOptions
{
    public double spacing = 64;
    public double range = 96;
    public double standingEye = 1.6;
    public double crouchEye = 1.0;
    public double nearbyCover = 20;
    public int directions = 16;
    public int maxSamples = 1024;
}

public sealed class TacticalExposureSample
{
    public double x, z, standingOpen, crouchOpen, nearbyBlocked;
    public int directions;
    public string district = "wilderness";
    public bool exposed;
}

public sealed class TacticalDistrictExposure
{
    public string id = "";
    public int samples, exposedSamples;
    public double meanStandingOpen, meanCrouchOpen;
}

public sealed class TacticalExposureReport
{
    public int triangles, samples, omittedWater, omittedBuildings, rays, exposedSamples;
    public TacticalExposureSample[] points = Array.Empty<TacticalExposureSample>();
    public TacticalDistrictExposure[] districts = Array.Empty<TacticalDistrictExposure>();
}

public static class TacticalExposureReview
{
    private static string N(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);

    private static void CheckOptions(TacticalExposureOptions o)
    {
        if (o == null || !WorldValidator.Finite(o.spacing, o.range, o.standingEye, o.crouchEye, o.nearbyCover) ||
            o.spacing < 16 || o.spacing > 128 || o.range < 20 || o.range > 200 ||
            o.standingEye < 1.2 || o.standingEye > 2.2 || o.crouchEye < 0.5 ||
            o.crouchEye >= o.standingEye || o.nearbyCover < 3 || o.nearbyCover > o.range ||
            o.directions < 8 || o.directions > 32 || o.maxSamples < 1 || o.maxSamples > 1024)
            throw new ArgumentException("Tactical exposure needs finite, bounded sampling and standing/crouch settings.");
    }

    private static bool InLake(WorldSpec w, double x, double z)
    {
        foreach (var lake in w.terrain.lakes)
        {
            double dx = (x - lake.x) / lake.radiusX, dz = (z - lake.z) / lake.radiusZ;
            if (dx * dx + dz * dz <= 1) return true;
        }
        return false;
    }

    // Source-BVH hits use both sides of static triangles for conservative cover.
    public static TacticalExposureSample SampleAt(CollisionBvh bvh, TerrainSampler terrain, GridSpec grid,
        double x, double z, TacticalExposureOptions options)
    {
        CheckOptions(options);
        if (bvh == null || terrain == null || grid == null || !WorldValidator.Finite(x, z) ||
            x < grid.originX || z < grid.originZ || x >= grid.originX + grid.sizeX ||
            z >= grid.originZ + grid.sizeZ)
            throw new ArgumentException("Sample must be inside a finite world grid.");

        int visibleStanding = 0, visibleCrouch = 0, nearbyBlocked = 0, evaluated = 0;
        for (int i = 0; i < options.directions; i++)
        {
            double angle = i * (2 * Math.PI / options.directions), dx = Math.Cos(angle), dz = Math.Sin(angle);
            double extent = options.range;
            if (dx > 1e-9) extent = Math.Min(extent, (grid.originX + grid.sizeX - 0.01 - x) / dx);
            if (dx < -1e-9) extent = Math.Min(extent, (grid.originX + 0.01 - x) / dx);
            if (dz > 1e-9) extent = Math.Min(extent, (grid.originZ + grid.sizeZ - 0.01 - z) / dz);
            if (dz < -1e-9) extent = Math.Min(extent, (grid.originZ + 0.01 - z) / dz);
            if (extent < 5) continue;

            double endX = x + dx * extent, endZ = z + dz * extent;
            double startY = terrain.Height(x, z), endY = terrain.Height(endX, endZ);
            var standingOrigin = new Point3(x, startY + options.standingEye, z);
            var standingDirection = new Point3(endX, endY + options.standingEye, endZ) - standingOrigin;
            bool standingHit = bvh.Raycast(standingOrigin, standingDirection, standingDirection.Length, out var standingContact, true);
            if (!standingHit) visibleStanding++;
            else if (standingContact.distance <= options.nearbyCover) nearbyBlocked++;

            var crouchOrigin = new Point3(x, startY + options.crouchEye, z);
            var crouchDirection = new Point3(endX, endY + options.crouchEye, endZ) - crouchOrigin;
            if (!bvh.Raycast(crouchOrigin, crouchDirection, crouchDirection.Length, out _, true)) visibleCrouch++;
            evaluated++;
        }
        double standing = evaluated == 0 ? 0 : (double)visibleStanding / evaluated;
        double crouching = evaluated == 0 ? 0 : (double)visibleCrouch / evaluated;
        double nearby = evaluated == 0 ? 0 : (double)nearbyBlocked / evaluated;
        return new TacticalExposureSample
        {
            x = x, z = z, directions = evaluated, standingOpen = standing,
            crouchOpen = crouching, nearbyBlocked = nearby,
            exposed = evaluated >= 4 && standing >= 0.75 && crouching >= 0.6 && nearby <= 0.125
        };
    }

    public static TacticalExposureReport Analyze(WorldSpec world, AssetRegistry registry, TacticalExposureOptions options)
    {
        CheckOptions(options);
        var errors = WorldValidator.Validate(world, registry);
        if (errors.Count != 0) throw new InvalidOperationException("Invalid world: " + errors[0]);
        var grid = world.grid;
        int nx = (int)Math.Ceiling(grid.sizeX / options.spacing), nz = (int)Math.Ceiling(grid.sizeZ / options.spacing);
        if ((long)nx * nz > options.maxSamples || 2L * nx * nz * options.directions > 65536)
            throw new InvalidOperationException("Tactical analysis exceeds sample/ray budget; enlarge spacing or analyze a smaller world.");

        var terrain = new TerrainSampler(world);
        var bvh = CollisionBvh.FromWorld(world, registry);
        var assetLookup = registry.assets.ToDictionary(a => a.id, StringComparer.Ordinal);
        var buildings = world.objects.Where(o =>
        {
            var a = assetLookup[o.asset];
            return a.previewShape == "building" || a.previewShape == "tower";
        }).Select(o => Geometry.Footprint(o, assetLookup[o.asset])).ToArray();
        var points = new List<TacticalExposureSample>();
        int water = 0, occupied = 0;
        for (int iz = 0; iz < nz; iz++)
        {
            double z = grid.originZ + grid.sizeZ * (iz + 0.5) / nz;
            for (int ix = 0; ix < nx; ix++)
            {
                double x = grid.originX + grid.sizeX * (ix + 0.5) / nx;
                if (InLake(world, x, z)) { water++; continue; }
                if (buildings.Any(poly => Geometry.Contains(poly, new Point2(x, z)))) { occupied++; continue; }
                var sample = SampleAt(bvh, terrain, grid, x, z, options);
                var landmark = world.landmarks.OrderBy(l => l.id, StringComparer.Ordinal)
                    .FirstOrDefault(l => WorldDesign.Distance(new Point2(l.x, l.z), new Point2(x, z)) <= l.radius);
                sample.district = landmark == null ? "wilderness" : landmark.id;
                points.Add(sample);
            }
        }
        var districts = world.landmarks.OrderBy(l => l.id, StringComparer.Ordinal).Select(l =>
        {
            var local = points.Where(p => p.district == l.id).ToArray();
            return new TacticalDistrictExposure
            {
                id = l.id, samples = local.Length, exposedSamples = local.Count(p => p.exposed),
                meanStandingOpen = local.Length == 0 ? 0 : local.Average(p => p.standingOpen),
                meanCrouchOpen = local.Length == 0 ? 0 : local.Average(p => p.crouchOpen)
            };
        }).ToArray();
        return new TacticalExposureReport
        {
            triangles = bvh.TriangleCount, samples = points.Count, omittedWater = water,
            omittedBuildings = occupied, rays = points.Sum(p => p.directions) * 2,
            exposedSamples = points.Count(p => p.exposed), points = points.ToArray(), districts = districts
        };
    }

    public static void Write(WorldSpec world, AssetRegistry registry, string directory)
    {
        var options = new TacticalExposureOptions();
        var report = Analyze(world, registry, options);
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "tactical-exposure.json"), WorldFiles.Serialize(new
        {
            world = world.id, world.revision, worldSourceSha256 = WorldFiles.Fingerprint(),
            options, report,
            interpretation = "Standing/crouch eye heights, fixed world-space bearings, static-source triangles. Samples exclude water/building interiors. Not verified player visibility, navigation, loot balance, multiplayer physics, measured FPS or final art.",
            warningRule = "Authoring flag only: >=75% standing directions open, >=60% crouch open and <=12.5% near occluders. Inspect in Unity before moving objects."
        }));
        var g = world.grid;
        double scale = 900 / Math.Max(g.sizeX, g.sizeZ);
        var overlay = new StringBuilder();
        foreach (var s in report.points)
        {
            int red = (int)Math.Round(65 + s.standingOpen * 190);
            int green = (int)Math.Round(198 - s.standingOpen * 145);
            double cx = 64 + (s.x - g.originX) * scale;
            double cy = 64 + (g.originZ + g.sizeZ - s.z) * scale;
            string description = SecurityElement.Escape(s.district + ": standing " + N(s.standingOpen * 100) +
                "% open, crouch " + N(s.crouchOpen * 100) + "%, near blockers " + N(s.nearbyBlocked * 100) + "%");
            overlay.Append("<circle cx=\"").Append(N(cx)).Append("\" cy=\"").Append(N(cy))
                .Append("\" r=\"8\" fill=\"rgb(").Append(red).Append(",").Append(green)
                .Append(",60)\" fill-opacity=\"0.66\" stroke=\"")
                .Append(s.exposed ? "#ff4949" : "#10252b")
                .Append("\" stroke-width=\"").Append(s.exposed ? "2" : "0.6").Append("\"><title>")
                .Append(description).Append("</title></circle>");
        }
        overlay.Append("<text x=\"64\" y=\"1070\" font-size=\"11\" font-family=\"sans-serif\" fill=\"#e4edf2\">")
            .Append("STATIC TACTICAL EXPOSURE / RED HIGHER OPENNESS / BRIGHT RIM REVIEW FLAG / NOT UNITY RENDER")
            .Append("</text>");
        File.WriteAllText(Path.Combine(directory, "tactical-exposure.svg"),
            ReviewWriter.Svg(world, registry).Replace("</svg>", overlay + "</svg>"));
        Console.WriteLine("Tactical exposure: " + report.samples + " playable-grid samples, " +
            report.exposedSamples + " flagged, " + report.rays + " offline rays; map unchanged. No APK.");
    }
}
