using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    // A continuous mitered ribbon per road, followed by planar polygon subtraction.
    // Intersections share one visible surface instead of stacked coplanar strips.
    public static class RoadSurface
    {
        public static ArtMesh Network(WorldSpec world)
        {
            var terrain = new TerrainSampler(world);
            var triangles = new List<Point2[]>();
            var buckets = new Dictionary<CellKey, List<int>>();
            var vertices = new List<ArtVertex>(); var indices = new List<int>();
            foreach (var road in world.roads.OrderBy(r => r.id, StringComparer.Ordinal))
            {
                var ribbon = Ribbon(road, world.terrain.gridSpacing);
                for (int i = 0; i < ribbon.Count; i++)
                {
                    var triangle = ribbon[i];
                    var candidateIds = new HashSet<int>();
                    foreach (var key in Buckets(triangle))
                        if (buckets.TryGetValue(key, out var ids)) foreach (int id in ids) candidateIds.Add(id);
                    var pieces = new List<Point2[]> { triangle };
                    foreach (int id in candidateIds.OrderBy(id => id))
                    {
                        pieces = pieces.SelectMany(piece => Difference(piece, triangles[id])).ToList();
                        if (pieces.Count == 0) break;
                    }
                    foreach (var piece in pieces)
                    {
                        int start = vertices.Count;
                        foreach (var p in piece) vertices.Add(new ArtVertex(p.x, terrain.Height(p.x, p.z) + 0.12, p.z, p.x / 6, p.z / 6));
                        for (int j = 1; j < piece.Length - 1; j++)
                        {
                            if (Math.Abs(Cross(piece[0], piece[j], piece[j + 1])) < 1e-7) continue;
                            // Positive Y normal corresponds to clockwise winding in X/Z.
                            if (Cross(piece[0], piece[j], piece[j + 1]) < 0) indices.AddRange(new[] { start, start + j, start + j + 1 });
                            else indices.AddRange(new[] { start, start + j + 1, start + j });
                        }
                    }
                    int index = triangles.Count; triangles.Add(triangle);
                    foreach (var key in Buckets(triangle))
                    {
                        if (!buckets.TryGetValue(key, out var ids)) { ids = new List<int>(); buckets.Add(key, ids); }
                        ids.Add(index);
                    }
                }
            }
            return new ArtMesh { material = "road", vertices = vertices.ToArray(), triangles = indices.ToArray() };
        }

        private static IEnumerable<CellKey> Buckets(Point2[] polygon)
        {
            int minX = (int)Math.Floor(polygon.Min(p => p.x) / 16), maxX = (int)Math.Floor(polygon.Max(p => p.x) / 16);
            int minZ = (int)Math.Floor(polygon.Min(p => p.z) / 16), maxZ = (int)Math.Floor(polygon.Max(p => p.z) / 16);
            for (int z = minZ; z <= maxZ; z++) for (int x = minX; x <= maxX; x++) yield return new CellKey(x, z);
        }

        private static List<Point2[]> Ribbon(RoadSpec road, double spacing)
        {
            var samples = WorldDesign.SampleRoute(new RouteSpec { points = road.points }, spacing).ToArray();
            var left = new Point2[samples.Length]; var right = new Point2[samples.Length];
            bool closed = WorldDesign.Distance(samples[0], samples[samples.Length - 1]) < 0.001;
            for (int i = 0; i < samples.Length; i++)
            {
                var p = samples[i];
                var previous = samples[i > 0 ? i - 1 : closed ? samples.Length - 2 : 0];
                var next = samples[i < samples.Length - 1 ? i + 1 : closed ? 1 : i];
                double ax = p.x - previous.x, az = p.z - previous.z, bx = next.x - p.x, bz = next.z - p.z;
                double al = Math.Sqrt(ax * ax + az * az), bl = Math.Sqrt(bx * bx + bz * bz);
                if (al < 0.001) { ax = bx; az = bz; al = bl; }
                if (bl < 0.001) { bx = ax; bz = az; bl = al; }
                ax /= al; az /= al; bx /= bl; bz /= bl;
                double nx = -az - bz, nz = ax + bx, length = Math.Sqrt(nx * nx + nz * nz);
                if (length < 0.001) { nx = -bz; nz = bx; length = 1; }
                nx /= length; nz /= length;
                double dot = Math.Max(0.5, nx * -bz + nz * bx), scale = road.width * 0.5 / dot;
                left[i] = new Point2(p.x + nx * scale, p.z + nz * scale); right[i] = new Point2(p.x - nx * scale, p.z - nz * scale);
            }
            var result = new List<Point2[]>();
            for (int i = 1; i < samples.Length; i++)
            {
                result.Add(new[] { right[i - 1], left[i - 1], right[i] });
                result.Add(new[] { left[i - 1], left[i], right[i] });
            }
            return result;
        }

        private static double Cross(Point2 a, Point2 b, Point2 p) => (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x);

        public static List<Point2[]> Difference(Point2[] polygon, Point2[] clip)
        {
            var output = new List<Point2[]>(); var remainder = polygon;
            double sign = Math.Sign(Cross(clip[0], clip[1], clip[2]));
            if (sign == 0) { output.Add(polygon); return output; }
            for (int i = 0; i < clip.Length && remainder.Length >= 3; i++)
            {
                var a = clip[i]; var b = clip[(i + 1) % clip.Length];
                var outside = HalfPlane(remainder, a, b, -sign);
                if (outside.Length >= 3 && Area(outside) > 1e-7) output.Add(outside);
                remainder = HalfPlane(remainder, a, b, sign);
            }
            return output;
        }

        private static Point2[] HalfPlane(Point2[] polygon, Point2 a, Point2 b, double sign)
        {
            var result = new List<Point2>();
            var previous = polygon[polygon.Length - 1]; double dp = Cross(a, b, previous) * sign;
            foreach (var p in polygon)
            {
                double dc = Cross(a, b, p) * sign;
                bool previousInside = dp >= 0, currentInside = dc >= 0;
                if (previousInside != currentInside)
                {
                    double t = dp / (dp - dc);
                    result.Add(new Point2(previous.x + (p.x - previous.x) * t, previous.z + (p.z - previous.z) * t));
                }
                if (currentInside) result.Add(p);
                previous = p; dp = dc;
            }
            return result.ToArray();
        }

        public static double Area(Point2[] polygon)
        {
            double sum = 0;
            for (int i = 0; i < polygon.Length; i++) { var p = polygon[i]; var q = polygon[(i + 1) % polygon.Length]; sum += p.x * q.z - q.x * p.z; }
            return Math.Abs(sum) * 0.5;
        }
    }
}
