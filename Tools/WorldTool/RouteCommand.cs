using System.Globalization;
using Aaris.World;

namespace Aaris.Tools;

public sealed class RouteRequest
{
    public int expectedRevision;
    public Point2? start;
    public Point2? end;
    public RoutePlanOptions options = new();
}

public static class RouteCommand
{
    public static RouteProposal Propose(WorldSpec world, AssetRegistry registry, RouteRequest request)
    {
        if (request == null || request.expectedRevision != world.revision) throw new InvalidOperationException("Stale route request: read the current revision.");
        if (!request.start.HasValue || !request.end.HasValue) throw new ArgumentException("Both start and end are required; endpoints never default to the origin.");
        return RoutePlanner.Plan(world, registry, request.start.Value, request.end.Value, request.options);
    }

    public static void Write(WorldSpec world, AssetRegistry registry, RouteRequest request, string directory)
    {
        var proposal = Propose(world, registry, request);
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "route-proposal.json"), WorldFiles.Serialize(new {
            world = world.id, world.revision, sourceSha256 = WorldFiles.Fingerprint(), request, proposal,
            scope = "Outdoor authoring proposal. Continuous conservative footprint/water clearance, sampled centreline slope. Not NavMesh, vehicle suitability or approved combat balance. Source unchanged."
        }));
        double factor = 900 / Math.Max(world.grid.sizeX, world.grid.sizeZ);
        string N(double n) => n.ToString("0.###", CultureInfo.InvariantCulture);
        string points = string.Join(" ", proposal.points.Select(p => N(64 + (p.x - world.grid.originX) * factor) + "," + N(64 + (world.grid.originZ + world.grid.sizeZ - p.z) * factor)));
        string overlay = "<polyline points=\"" + points + "\" fill=\"none\" stroke=\"#15222c\" stroke-width=\"7\"/><polyline points=\"" + points + "\" fill=\"none\" stroke=\"#fa73d4\" stroke-width=\"3\"/><text x=\"64\" y=\"1053\" font-size=\"11\" font-family=\"sans-serif\" fill=\"#fa73d4\">MAGENTA: OUTDOOR ROUTE PROPOSAL / SOURCE UNCHANGED</text>";
        File.WriteAllText(Path.Combine(directory, "route-proposal.svg"), ReviewWriter.Svg(world, registry).Replace("</svg>", overlay + "</svg>"));
        Console.WriteLine($"Route proposal: {proposal.length:0.0} m, {proposal.expandedNodes} nodes, {proposal.maxSampledSlope:0.0}° sampled maximum. Source unchanged; no APK compiled.");
    }
}
