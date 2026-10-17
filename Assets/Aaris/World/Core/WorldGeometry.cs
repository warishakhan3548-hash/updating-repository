using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    public static class WorldGeometry
    {
        public static ArtMesh Terrain(WorldSpec w, CellKey cell)
        {
            var sampler = new TerrainSampler(w);
            int n = (int)Math.Round(w.grid.cellSize / w.terrain.gridSpacing), side = n + 1;
            double minX = w.grid.originX + cell.x * w.grid.cellSize, minZ = w.grid.originZ + cell.z * w.grid.cellSize;
            var vertices = new ArtVertex[side * side]; var indices = new List<int>();
            for (int z = 0; z <= n; z++) for (int x = 0; x <= n; x++)
            {
                double wx = minX + x * w.terrain.gridSpacing, wz = minZ + z * w.terrain.gridSpacing;
                var v = new ArtVertex(x * w.terrain.gridSpacing, sampler.VertexHeight(wx, wz), z * w.terrain.gridSpacing, wx / 8, wz / 8);
                var color = SurfaceColor(w, sampler, wx, wz);
                v.r = color[0]; v.g = color[1]; v.b = color[2]; vertices[z * side + x] = v;
            }
            for (int z = 0; z < n; z++) for (int x = 0; x < n; x++)
            {
                int a = z * side + x, b = a + 1, c = a + side, d = c + 1;
                indices.AddRange(new[] { a, c, b, b, c, d });
            }
            return new ArtMesh { material = "terrain", vertices = vertices, triangles = indices.ToArray() };
        }

        public static byte[] SurfaceColor(WorldSpec w, TerrainSampler terrain, double x, double z)
        {
            double[] color = { 109, 130, 76 };
            foreach (var biome in w.biomes)
            {
                double q = Math.Pow((x - biome.x) / biome.radiusX, 2) + Math.Pow((z - biome.z) / biome.radiusZ, 2);
                double weight = Math.Max(0, Math.Min(1, 2 - q));
                for (int i = 0; i < 3; i++) color[i] += (Convert.ToInt32(biome.color.Substring(1 + i * 2, 2), 16) - color[i]) * weight;
            }
            double rock = Math.Max(0, Math.Min(0.85, (terrain.SlopeDegrees(x, z) - 18) / 22));
            double[] rockColor = { 119, 122, 109 };
            for (int i = 0; i < 3; i++) color[i] += (rockColor[i] - color[i]) * rock;
            foreach (var lake in w.terrain.lakes)
            {
                double q = Math.Sqrt(Math.Pow((x - lake.x) / lake.radiusX, 2) + Math.Pow((z - lake.z) / lake.radiusZ, 2));
                double sand = Math.Max(0, 1 - Math.Abs(q - 1) / 0.3);
                double[] shore = { 162, 151, 113 };
                for (int i = 0; i < 3; i++) color[i] += (shore[i] - color[i]) * sand;
            }
            // Avoid visible periodic striping; the seed-locked broad and local
            // variation agrees exactly where neighbouring terrain cells meet.
            double variation = terrain.SurfaceVariation(x, z);
            return color.Select(c => (byte)Math.Max(0, Math.Min(255, c * variation))).ToArray();
        }

        public static ArtMesh Water(LakeSpec lake)
        {
            const int segments = 96;
            var vertices = new List<ArtVertex> { new ArtVertex(lake.x, lake.surfaceY + 0.025, lake.z) }; var indices = new List<int>();
            for (int i = 0; i < segments; i++)
            {
                double a = i * 2 * Math.PI / segments;
                vertices.Add(new ArtVertex(lake.x + Math.Cos(a) * lake.radiusX, lake.surfaceY + 0.025, lake.z + Math.Sin(a) * lake.radiusZ, Math.Cos(a), Math.Sin(a)));
            }
            for (int i = 0; i < segments; i++) indices.AddRange(new[] { 0, 1 + (i + 1) % segments, 1 + i });
            return new ArtMesh { material = "water", vertices = vertices.ToArray(), triangles = indices.ToArray() };
        }
    }
}
