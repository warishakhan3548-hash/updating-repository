using System.Globalization;
using System.Security;
using System.Text;
using Aaris.World;

namespace Aaris.Tools;

public static class ReviewWriter
{
    private static string N(double n) => n.ToString("0.###", CultureInfo.InvariantCulture);
    private static string E(string s) => SecurityElement.Escape(s) ?? "";

    public static void Write(WorldSpec world, AssetRegistry registry, string directory)
    {
        var plan = WorldCompiler.Compile(world, registry);
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "world-plan.json"), WorldFiles.Serialize(plan));
        File.WriteAllText(Path.Combine(directory, "top-view.svg"), Svg(world, registry));
        string fingerprint = WorldFiles.Fingerprint();
        var summary = new
        {
            schemaVersion = 1, world = world.id, world.revision, world.seed,
            sourceSha256 = fingerprint, cells = plan.cells.Length, objects = plan.objects.Length,
            blockoutAssets = registry.assets.Count(a => string.IsNullOrEmpty(a.prefabPath)),
            peakEstimatedTriangles = plan.cells.Max(c => c.cost.triangles),
            peakEstimatedMaterialSlots = plan.cells.Max(c => c.cost.materialSlots),
            peakEstimatedTextureKiB = plan.cells.Max(c => c.cost.textureKiB),
            peakEstimatedColliders = plan.cells.Max(c => c.cost.colliders),
            estimateScope = "Static placement references and terrain only. Not runtime memory, batching, GPU time or draw calls. Roads, effects and dynamic actors require profiling."
        };
        File.WriteAllText(Path.Combine(directory, "metrics.json"), WorldFiles.Serialize(summary));
        File.WriteAllText(Path.Combine(directory, "README.md"),
            "# " + world.id + " / revision " + world.revision + "\n\n" +
            "`top-view.svg` is a schematic layout review, not a Unity render or final visual quality. North (+Z) is up; dimensions are metres.\n\n" +
            "`world-plan.json` contains resolved ground heights, unique owner cells and cross-cell references. `metrics.json` contains conservative authoring estimates.\n\n" +
            "Source SHA-256: `" + fingerprint + "`\n\nActual Unity perspective PNGs are produced separately by `Aaris.World.Editor.WorldReview.Render` on a licensed Unity graphics runner. No APK is produced.\n");
    }

    public static string Svg(WorldSpec world, AssetRegistry registry)
    {
        var g = world.grid;
        const double margin = 64;
        double factor = 900 / Math.Max(g.sizeX, g.sizeZ), width = g.sizeX * factor, height = g.sizeZ * factor;
        double X(double x) => margin + (x - g.originX) * factor;
        double Z(double z) => margin + (g.originZ + g.sizeZ - z) * factor;
        var sb = new StringBuilder();
        sb.Append("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " + N(width + 128) + " " + N(height + 170) + "\">");
        sb.Append("<rect width=\"100%\" height=\"100%\" fill=\"#111b23\"/><g font-family=\"sans-serif\" fill=\"#e4edf2\">");
        sb.Append("<text x=\"64\" y=\"28\" font-size=\"20\">AARIS / " + E(world.id) + " / r" + world.revision + "</text>");
        sb.Append("<text x=\"64\" y=\"48\" font-size=\"12\">LAYOUT REVIEW / architectural blockout / N +Z ↑ / grid " + N(g.cellSize) + " m</text>");
        var terrain = new TerrainSampler(world);
        double tile = Math.Max(g.sizeX, g.sizeZ) / 96;
        for (double z = g.originZ; z < g.originZ + g.sizeZ - 0.001; z += tile)
            for (double x = g.originX; x < g.originX + g.sizeX - 0.001; x += tile)
            {
                double high = terrain.Height(x, z);
                int tone = (int)Math.Clamp(55 + high * 3, 35, 150);
                sb.Append("<rect x=\"" + N(X(x)) + "\" y=\"" + N(Z(Math.Min(z + tile, g.originZ + g.sizeZ))) + "\" width=\"" + N(Math.Min(tile, g.originX + g.sizeX - x) * factor + 0.1) +
                    "\" height=\"" + N(Math.Min(tile, g.originZ + g.sizeZ - z) * factor + 0.1) + "\" fill=\"rgb(" + (tone - 18) + "," + tone + "," + (tone - 8) + ")\"/>");
            }
        foreach (var road in world.roads)
        {
            string points = string.Join(" ", road.points.Select(p => N(X(p.x)) + "," + N(Z(p.z))));
            sb.Append("<polyline points=\"" + points + "\" fill=\"none\" stroke=\"#34434b\" stroke-width=\"" + N((road.width + 2 * road.clearance) * factor) + "\" stroke-linejoin=\"round\"/>");
            sb.Append("<polyline points=\"" + points + "\" fill=\"none\" stroke=\"#a6b1ad\" stroke-width=\"" + N(road.width * factor) + "\" stroke-linejoin=\"round\"/>");
        }
        int nx = (int)Math.Round(g.sizeX / g.cellSize), nz = (int)Math.Round(g.sizeZ / g.cellSize);
        for (int x = 0; x <= nx; x++)
            sb.Append("<path d=\"M" + N(X(g.originX + x * g.cellSize)) + " " + N(margin) + "v" + N(height) + "\" stroke=\"#ffffff\" stroke-opacity=\"0.12\"/>");
        for (int z = 0; z <= nz; z++)
            sb.Append("<path d=\"M" + N(margin) + " " + N(Z(g.originZ + z * g.cellSize)) + "h" + N(width) + "\" stroke=\"#ffffff\" stroke-opacity=\"0.12\"/>");
        var assets = registry.assets.ToDictionary(a => a.id);
        foreach (var o in world.objects.OrderBy(o => o.id, StringComparer.Ordinal))
        {
            var a = assets[o.asset];
            string points = string.Join(" ", Geometry.Footprint(o, a).Select(p => N(X(p.x)) + "," + N(Z(p.z))));
            sb.Append("<polygon points=\"" + points + "\" fill=\"" + a.color + "\" stroke=\"#15272d\" stroke-width=\"0.8\"><title>" + E(o.id) + " / " + E(o.asset) + " / X " + N(o.x) + " Z " + N(o.z) + "</title></polygon>");
            if (a.previewShape == "building" || a.previewShape == "tower")
                sb.Append("<text x=\"" + N(X(o.x)) + "\" y=\"" + N(Z(o.z) - a.depth * factor * o.scale * 0.5 - 2) + "\" text-anchor=\"middle\" font-size=\"6\">" + E(o.id) + "</text>");
        }
        foreach (var p in world.landmarks)
        {
            sb.Append("<circle cx=\"" + N(X(p.x)) + "\" cy=\"" + N(Z(p.z)) + "\" r=\"" + N(p.radius * factor) + "\" fill=\"none\" stroke=\"#dcce8d\" stroke-dasharray=\"4 5\" stroke-opacity=\"0.6\"/>");
            sb.Append("<text x=\"" + N(X(p.x)) + "\" y=\"" + N(Z(p.z) - p.radius * factor - 5) + "\" text-anchor=\"middle\" font-size=\"13\" fill=\"#f4e4a7\">" + E(p.name) + "</text>");
        }
        foreach (var m in world.markers)
        {
            sb.Append("<circle cx=\"" + N(X(m.x)) + "\" cy=\"" + N(Z(m.z)) + "\" r=\"5\" fill=\"#71e9ec\"/>");
            sb.Append("<text x=\"" + N(X(m.x) + 7) + "\" y=\"" + N(Z(m.z)) + "\" font-size=\"9\">" + E(m.id) + "</text>");
        }
        sb.Append("<text x=\"64\" y=\"" + N(height + 95) + "\" font-size=\"12\">" + world.objects.Length + " objects / " + nx * nz + " cells / " + N(g.sizeX) + " × " + N(g.sizeZ) + " m / seed " + world.seed + "</text>");
        sb.Append("<text x=\"64\" y=\"" + N(height + 116) + "\" font-size=\"11\" fill=\"#a2b4bd\">Terrain + roads + stable object IDs. Schematic authoring view; final art and gameplay are later stages.</text></g></svg>\n");
        return sb.ToString();
    }
}
