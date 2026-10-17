using Aaris.World;

namespace Aaris.Tools;

public static class GeometryExporter
{
    public static void Write(WorldSpec w, AssetRegistry registry, string directory)
    {
        var plan = WorldCompiler.Compile(w, registry);
        Directory.CreateDirectory(directory); Directory.CreateDirectory(Path.Combine(directory, "textures"));
        var assets = registry.assets.Where(a => a.archetype.Length > 0).ToArray();
        if (assets.Length != registry.assets.Length || assets.Any(a => !string.IsNullOrEmpty(a.prefabPath)))
            throw new InvalidOperationException("Offline export requires procedural v2 assets without external prefab overrides. External prefabs must be reviewed in Unity.");
        var models = assets.ToDictionary(a => a.id, a => new { parts = ProceduralArt.Create(a, 0).parts });
        var used = models.Values.SelectMany(m => m.parts.Select(p => p.material)).ToHashSet(StringComparer.Ordinal);
        var surfaces = assets.SelectMany(ArtPalette.Surfaces).Where(s => used.Contains(s.id)).GroupBy(s => s.id).Select(g => g.First()).ToList();
        surfaces.AddRange(new[] {
            new PbrSurface { id = "terrain", color = "#ffffff", pattern = "stone", roughness = 0.95, bump = 0.08 },
            new PbrSurface { id = "road", color = "#77766a", pattern = "stone", roughness = 0.9, bump = 0.05 },
            new PbrSurface { id = "water", color = "#386a70", pattern = "plain", roughness = 0.16, metallic = 0.15, bump = 0 }
        });
        foreach (var s in surfaces)
            WritePpm(Path.Combine(directory, "textures", s.id + ".ppm"), ArtPalette.Albedo(s, w.visuals.textureResolution), w.visuals.textureResolution);
        var scene = new {
            formatVersion = 1, sourceSha256 = WorldFiles.Fingerprint(), world = w.id, w.revision, visuals = w.visuals,
            note = "C# source geometry rendered offline. Not a Unity frame, game client, physics test or mobile performance result.",
            models, surfaces, placements = plan.objects,
            terrain = plan.cells.Select(c => new { id = c.key.ToString(), x = w.grid.originX + c.key.x * w.grid.cellSize,
                z = w.grid.originZ + c.key.z * w.grid.cellSize, mesh = WorldGeometry.Terrain(w, c.key) }).ToArray(),
            roads = new[] { RoadSurface.Network(w) },
            water = w.terrain.lakes.Select(WorldGeometry.Water).ToArray(),
            landmarks = w.landmarks
        };
        File.WriteAllText(Path.Combine(directory, "scene.json"), WorldFiles.Serialize(scene));
        Console.WriteLine("Shared C# geometry exported to " + directory + "; no APK or Unity player build.");
    }

    private static void WritePpm(string path, byte[] rgba, int size)
    {
        using var stream = File.Create(path);
        var header = System.Text.Encoding.ASCII.GetBytes($"P6\n{size} {size}\n255\n"); stream.Write(header);
        for (int i = 0; i < rgba.Length; i += 4) stream.Write(rgba, i, 3);
    }
}
