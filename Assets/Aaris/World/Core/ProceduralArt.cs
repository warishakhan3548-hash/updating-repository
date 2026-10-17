using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    [Serializable]
    public struct ArtVertex
    {
        public float x, y, z, u, v;
        public byte r, g, b;
        public ArtVertex(double x, double y, double z, double u = 0, double v = 0)
        { this.x = (float)x; this.y = (float)y; this.z = (float)z; this.u = (float)u; this.v = (float)v; r = g = b = 255; }
    }

    [Serializable]
    public sealed class ArtMesh
    {
        public string material;
        public ArtVertex[] vertices;
        public int[] triangles;
    }

    [Serializable]
    public sealed class ArtModel
    {
        public ArtMesh[] parts;
        public ArtMesh collision;
        public int TriangleCount { get { return parts.Sum(p => p.triangles.Length / 3); } }
    }

    [Serializable]
    public sealed class PbrSurface
    {
        public string id;
        public string color;
        public string pattern;
        public double roughness = 0.8;
        public double metallic;
        public double bump = 0.12;
    }

    public static class ArtPalette
    {
        public static PbrSurface[] Surfaces(AssetSpec a)
        {
            return new[] {
                new PbrSurface { id = a.id + "_wall", color = a.color, pattern = a.archetype == "warehouse" ? "metal" : "plaster" },
                new PbrSurface { id = a.id + "_roof", color = a.roofColor, pattern = "tile", roughness = 0.65 },
                new PbrSurface { id = "trim", color = "#d6ccad", pattern = "stone" },
                new PbrSurface { id = "wood", color = "#66513b", pattern = "wood" },
                new PbrSurface { id = "steel", color = "#59696a", pattern = "metal", metallic = 0.55, roughness = 0.5 },
                new PbrSurface { id = "glass", color = "#53788a", pattern = "plain", roughness = 0.19, bump = 0 },
                new PbrSurface { id = a.id + "_leaf", color = a.color, pattern = "leaf", roughness = 0.95 },
                new PbrSurface { id = a.id + "_rock", color = a.color, pattern = "stone", roughness = 0.94 }
            };
        }

        // Tileable original material data. Shared by Unity textures and offline geometry reviews.
        public static double Height(string pattern, double u, double v)
        {
            double noise = 0.5 + 0.18 * Math.Sin(2 * Math.PI * (17 * u + 13 * v)) + 0.1 * Math.Cos(2 * Math.PI * (31 * u - 23 * v));
            double Fract(double x) { return x - Math.Floor(x); }
            if (pattern == "tile")
            {
                double row = Math.Floor(v * 8), x = Fract(u * 6 + (row % 2) * 0.5), y = Fract(v * 8);
                return x < 0.035 || y < 0.06 ? 0.12 : 0.55 + 0.18 * Math.Cos(x * Math.PI) + noise * 0.12;
            }
            if (pattern == "wood") return 0.4 + 0.15 * Math.Sin(2 * Math.PI * (u * 28 + 0.2 * Math.Sin(v * 2 * Math.PI))) + noise * 0.12;
            if (pattern == "metal") return 0.5 + 0.2 * Math.Cos(u * 2 * Math.PI * 16) + noise * 0.04;
            if (pattern == "plaster") return 0.5 + (noise - 0.5) * 0.3;
            if (pattern == "leaf") return 0.6 + 0.14 * Math.Sin(u * 12 * Math.PI) * Math.Sin(v * 8 * Math.PI);
            if (pattern == "plain") return 0.5;
            return noise;
        }

        public static byte[] Albedo(PbrSurface surface, int size)
        {
            int r = Convert.ToInt32(surface.color.Substring(1, 2), 16), g = Convert.ToInt32(surface.color.Substring(3, 2), 16), b = Convert.ToInt32(surface.color.Substring(5, 2), 16);
            var pixels = new byte[size * size * 4];
            for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
            {
                double h = Height(surface.pattern, (double)x / size, (double)y / size), factor = 0.8 + h * 0.4;
                int i = (y * size + x) * 4;
                pixels[i] = (byte)Math.Min(255, r * factor); pixels[i + 1] = (byte)Math.Min(255, g * factor); pixels[i + 2] = (byte)Math.Min(255, b * factor); pixels[i + 3] = 255;
            }
            return pixels;
        }
    }

    // Geometry is built once per asset/LOD, then instanced. No per-placement mesh copies.
    public static class ProceduralArt
    {
        public static ArtModel Create(AssetSpec a, int lod)
        {
            if (lod < 0 || lod > 2) throw new ArgumentOutOfRangeException(nameof(lod));
            var b = new Builder();
            double w = a.width, d = a.depth, h = a.height;
            string wall = a.id + "_wall", roof = a.id + "_roof";
            if (a.archetype == "house" || a.archetype == "townhouse" || a.archetype == "warehouse" || a.archetype == "barn" || a.archetype == "station")
            {
                double roofH = Math.Min(h * 0.25, 2.4), bodyH = h - roofH;
                double bw = w - 0.8, bd = d - 1.4;
                b.Box("trim", 0, 0.15, 0, bw, 0.3, bd, true);
                if (lod == 2)
                    b.Box(wall, 0, bodyH / 2, 0, bw, bodyH, bd, false);
                else
                {
                    int floors = a.archetype == "townhouse" || a.archetype == "station" ? 2 : 1;
                    double floorH = bodyH / floors;
                    for (int floor = 0; floor < floors; floor++)
                    {
                        double bottom = floor * floorH;
                        if (floor > 0) b.Box("wood", 0, bottom, 0, bw - 0.3, 0.18, bd - 0.3, true);
                        Wall(b, wall, bw, floorH, bottom, bd / 2, false, floor == 0, a.archetype == "warehouse", lod);
                        Wall(b, wall, bw, floorH, bottom, -bd / 2, false, false, false, lod);
                        Wall(b, wall, bd, floorH, bottom, bw / 2, true, false, false, lod);
                        Wall(b, wall, bd, floorH, bottom, -bw / 2, true, false, false, lod);
                    }
                    // Front steps and veranda stay within the registered footprint.
                    b.Box("trim", 0, 0.10, d / 2 - 0.35, Math.Min(3.6, bw * 0.5), 0.20, 0.7, true);
                    if (lod == 0)
                    {
                        foreach (double x in new[] { -bw / 2, bw / 2 })
                            foreach (double z in new[] { -bd / 2, bd / 2 }) b.Box("trim", x, bodyH / 2, z, 0.28, bodyH, 0.28, false);
                        b.Box("trim", 0, bodyH - 0.12, 0, bw + 0.2, 0.24, bd + 0.2, false);
                    }
                }
                // Gable roof: closed top and triangular gables, no overhang outside source bounds.
                b.RoofPanel(roof, new ArtVertex(-w / 2, bodyH, -d / 2), new ArtVertex(-w / 2, bodyH, d / 2), new ArtVertex(0, h, d / 2), new ArtVertex(0, h, -d / 2));
                b.RoofPanel(roof, new ArtVertex(0, h, -d / 2), new ArtVertex(0, h, d / 2), new ArtVertex(w / 2, bodyH, d / 2), new ArtVertex(w / 2, bodyH, -d / 2));
                b.Triangle(wall, new ArtVertex(-w / 2, bodyH, d / 2), new ArtVertex(w / 2, bodyH, d / 2), new ArtVertex(0, h, d / 2), true);
                b.Triangle(wall, new ArtVertex(w / 2, bodyH, -d / 2), new ArtVertex(-w / 2, bodyH, -d / 2), new ArtVertex(0, h, -d / 2), true);
            }
            else if (a.archetype == "tower")
            {
                double platform = h - 3;
                foreach (double x in new[] { -w * 0.32, w * 0.32 }) foreach (double z in new[] { -d * 0.32, d * 0.32 })
                    b.Box("wood", x, platform / 2, z, 0.55, platform, 0.55, true);
                b.Box("wood", 0, platform, 0, w, 0.25, d, true);
                b.Box(roof, 0, h - 0.15, 0, w, 0.3, d, true);
                foreach (double x in new[] { -w * 0.42, w * 0.42 }) foreach (double z in new[] { -d * 0.42, d * 0.42 })
                    b.Box("wood", x, h - 1.5, z, 0.2, 3, 0.2, false);
                foreach (double z in new[] { -d * 0.45, d * 0.45 }) b.Box("wood", 0, platform + 0.9, z, w, 0.15, 0.18, false);
                if (lod == 0)
                    for (double y = 0.4; y < platform; y += 0.38) b.Box("steel", 0, y, -d * 0.28, 0.8, 0.08, 0.14, false);
            }
            else if (a.archetype == "oak" || a.archetype == "pine")
            {
                b.Cone("wood", 0, 0, 0, w * 0.055, w * 0.025, h * 0.65, lod == 0 ? 9 : 6, true);
                int segments = lod == 0 ? 12 : lod == 1 ? 8 : 5;
                if (a.archetype == "pine")
                    for (int i = 0; i < (lod == 2 ? 2 : 4); i++)
                    {
                        double y = h * (0.20 + i * (lod == 2 ? 0.28 : 0.16));
                        double radius = Math.Min(w, d) * (0.48 - i * (lod == 2 ? 0.16 : 0.085));
                        b.Cone(a.id + "_leaf", 0, y, 0, radius, 0.04, h * (lod == 2 ? 0.47 : 0.32), segments, false);
                    }
                else
                {
                    b.Ellipsoid(a.id + "_leaf", 0, h * 0.72, 0, w * 0.48, h * 0.28, d * 0.48, segments, lod == 0 ? 7 : 4, a.artSeed, false);
                    if (lod == 0)
                    {
                        b.Ellipsoid(a.id + "_leaf", w * 0.18, h * 0.56, 0, w * 0.28, h * 0.22, d * 0.32, 9, 5, a.artSeed + 1, false);
                        b.Ellipsoid(a.id + "_leaf", -w * 0.2, h * 0.61, d * 0.1, w * 0.27, h * 0.22, d * 0.3, 9, 5, a.artSeed + 2, false);
                    }
                }
            }
            else if (a.archetype == "boulder")
                b.Ellipsoid(a.id + "_rock", 0, h * 0.46, 0, w * 0.5, h * 0.5, d * 0.5, lod == 0 ? 14 : lod == 1 ? 9 : 6, lod == 0 ? 8 : 5, a.artSeed, true);
            else if (a.archetype == "barrier")
            {
                b.Box("trim", 0, h * 0.5, 0, w, h, d, true);
                if (lod == 0) foreach (double x in new[] { -w * 0.35, w * 0.35 }) b.Box("steel", x, h * 0.6, 0, 0.08, 0.12, d + 0.02, false);
            }
            else if (a.archetype == "crate")
            {
                b.Box("wood", 0, h / 2, 0, w, h, d, true);
                if (lod == 0) foreach (double z in new[] { -d * 0.36, d * 0.36 }) b.Box("steel", 0, h * 0.5, z, w + 0.02, h + 0.02, 0.08, false);
            }
            else b.Box(wall, 0, h * 0.5, 0, w, h, d, true);
            return b.Finish();
        }

        private static void Wall(Builder b, string material, double length, double height, double bottom, double fixedAxis, bool side, bool door, bool wideDoor, int lod)
        {
            void Box(string mat, double x, double y, double width, double high, double thickness, bool collision)
            { if (side) b.Box(mat, fixedAxis, bottom + y, x, thickness, high, width, collision); else b.Box(mat, x, bottom + y, fixedAxis, width, high, thickness, collision); }
            double doorWidth = wideDoor ? Math.Min(5, length * 0.45) : 1.6;
            if (door)
            {
                double top = Math.Min(height - 0.25, wideDoor ? 4 : 2.6);
                Box(material, 0, 0.15, doorWidth, 0.3, 0.28, true);
                Box(material, 0, (height + top) / 2, doorWidth, height - top, 0.28, true);
                Windows(-length / 2, -doorWidth / 2); Windows(doorWidth / 2, length / 2);
            }
            else Windows(-length / 2, length / 2);

            void Windows(double start, double end)
            {
                int count = Math.Max(1, (int)Math.Floor((end - start) / 3.8)); double bay = (end - start) / count;
                for (int i = 0; i < count; i++)
                {
                    double centre = start + bay * (i + 0.5), opening = Math.Min(bay - 0.7, 1.5);
                    double sill = 1, top = Math.Min(height - 0.35, 2.5), pier = (bay - opening) / 2;
                    Box(material, centre, sill / 2, bay, sill, 0.28, true);
                    Box(material, centre, (height + top) / 2, bay, height - top, 0.28, true);
                    foreach (double x in new[] { centre - (opening + pier) / 2, centre + (opening + pier) / 2 })
                        Box(material, x, (sill + top) / 2, pier, top - sill, 0.28, true);
                    Box("glass", centre, (sill + top) / 2, opening, top - sill, 0.06, false);
                    if (lod == 0)
                    {
                        Box("trim", centre, sill, opening + 0.2, 0.12, 0.4, false);
                        Box("trim", centre, top, opening + 0.2, 0.10, 0.4, false);
                        Box("wood", centre, (sill + top) / 2, 0.08, top - sill, 0.12, false);
                    }
                }
            }
        }

        private sealed class Builder
        {
            private readonly Dictionary<string, List<ArtVertex>> vertices = new Dictionary<string, List<ArtVertex>>(StringComparer.Ordinal);
            private readonly List<ArtVertex> collision = new List<ArtVertex>();
            public void Triangle(string material, ArtVertex a, ArtVertex b, ArtVertex c, bool collidable)
            {
                if (!vertices.TryGetValue(material, out var list)) { list = new List<ArtVertex>(); vertices.Add(material, list); }
                list.AddRange(new[] { a, b, c }); if (collidable) collision.AddRange(new[] { a, b, c });
            }
            public void Quad(string material, ArtVertex a, ArtVertex b, ArtVertex c, ArtVertex d, bool collidable)
            {
                // World-size UVs give a consistent texel density instead of stretching each panel.
                double width = Math.Sqrt(Math.Pow(b.x - a.x, 2) + Math.Pow(b.y - a.y, 2) + Math.Pow(b.z - a.z, 2)) / 3;
                double height = Math.Sqrt(Math.Pow(d.x - a.x, 2) + Math.Pow(d.y - a.y, 2) + Math.Pow(d.z - a.z, 2)) / 3;
                a.u = 0; a.v = 0; b.u = (float)width; b.v = 0; c.u = (float)width; c.v = (float)height; d.u = 0; d.v = (float)height;
                Triangle(material, a, b, c, collidable); Triangle(material, a, c, d, collidable);
            }
            public void Box(string material, double x, double y, double z, double w, double h, double d, bool collidable)
            {
                double l = x - w / 2, r = x + w / 2, low = y - h / 2, high = y + h / 2, back = z - d / 2, front = z + d / 2;
                Quad(material, new ArtVertex(l, low, front), new ArtVertex(r, low, front), new ArtVertex(r, high, front), new ArtVertex(l, high, front), collidable);
                Quad(material, new ArtVertex(r, low, back), new ArtVertex(l, low, back), new ArtVertex(l, high, back), new ArtVertex(r, high, back), collidable);
                Quad(material, new ArtVertex(r, low, front), new ArtVertex(r, low, back), new ArtVertex(r, high, back), new ArtVertex(r, high, front), collidable);
                Quad(material, new ArtVertex(l, low, back), new ArtVertex(l, low, front), new ArtVertex(l, high, front), new ArtVertex(l, high, back), collidable);
                Quad(material, new ArtVertex(l, high, front), new ArtVertex(r, high, front), new ArtVertex(r, high, back), new ArtVertex(l, high, back), collidable);
                Quad(material, new ArtVertex(l, low, back), new ArtVertex(r, low, back), new ArtVertex(r, low, front), new ArtVertex(l, low, front), collidable);
            }
            public void RoofPanel(string material, ArtVertex a, ArtVertex b, ArtVertex c, ArtVertex d)
            {
                Quad(material, a, b, c, d, false); // Preserve the reviewed visible geometry.
                var top = new[] { a, b, c, d };
                var bottom = top.Select(v => new ArtVertex(v.x, v.y - 0.14, v.z)).ToArray();
                void Face(ArtVertex p, ArtVertex q, ArtVertex r, ArtVertex s) { collision.AddRange(new[] { p, q, r, p, r, s }); }
                Face(a, b, c, d); Face(bottom[3], bottom[2], bottom[1], bottom[0]);
                for (int i = 0; i < 4; i++) { int next = (i + 1) % 4; Face(top[i], bottom[i], bottom[next], top[next]); }
            }
            public void Cone(string material, double x, double y, double z, double lower, double upper, double h, int segments, bool collidable)
            {
                for (int i = 0; i < segments; i++)
                {
                    double a = i * 2 * Math.PI / segments, b = (i + 1) * 2 * Math.PI / segments;
                    var p = new ArtVertex(x + lower * Math.Cos(a), y, z + lower * Math.Sin(a));
                    var q = new ArtVertex(x + lower * Math.Cos(b), y, z + lower * Math.Sin(b));
                    var r = new ArtVertex(x + upper * Math.Cos(b), y + h, z + upper * Math.Sin(b));
                    var s = new ArtVertex(x + upper * Math.Cos(a), y + h, z + upper * Math.Sin(a));
                    Quad(material, q, p, s, r, collidable);
                    Triangle(material, new ArtVertex(x, y, z), p, q, collidable);
                    Triangle(material, new ArtVertex(x, y + h, z), r, s, collidable);
                }
            }
            public void Ellipsoid(string material, double x, double y, double z, double rx, double ry, double rz, int segments, int rings, int seed, bool collidable)
            {
                ArtVertex P(int i, int j)
                {
                    double az = i * 2 * Math.PI / segments, el = j * Math.PI / rings;
                    double n = 0.92 + 0.08 * Math.Sin(az * 3 + seed) * Math.Sin(el * 2);
                    return new ArtVertex(x + rx * Math.Sin(el) * Math.Cos(az) * n, y + ry * Math.Cos(el) * n, z + rz * Math.Sin(el) * Math.Sin(az) * n, (double)i / segments, (double)j / rings);
                }
                for (int j = 0; j < rings; j++) for (int i = 0; i < segments; i++)
                {
                    var a = P(i, j); var b = P(i + 1, j); var c = P(i + 1, j + 1); var d = P(i, j + 1);
                    if (j > 0) Triangle(material, a, b, d, collidable);
                    if (j < rings - 1) Triangle(material, b, c, d, collidable);
                }
            }
            public ArtModel Finish()
            {
                ArtMesh Mesh(string material, List<ArtVertex> data) { return new ArtMesh { material = material, vertices = data.ToArray(), triangles = Enumerable.Range(0, data.Count).ToArray() }; }
                return new ArtModel { parts = vertices.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => Mesh(p.Key, p.Value)).ToArray(), collision = Mesh("collision", collision) };
            }
        }
    }
}
