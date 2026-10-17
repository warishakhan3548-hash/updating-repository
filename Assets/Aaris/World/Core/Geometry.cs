using System;
using System.Collections.Generic;

namespace Aaris.World
{
    public static class Geometry
    {
        public static Point2[] Footprint(ObjectSpec o, AssetSpec asset, double extra = 0)
        {
            double hx = asset.width * o.scale * 0.5 + extra;
            double hz = asset.depth * o.scale * 0.5 + extra;
            double angle = o.yaw * Math.PI / 180, c = Math.Cos(angle), s = Math.Sin(angle);
            var corners = new[] { new Point2(-hx, -hz), new Point2(hx, -hz), new Point2(hx, hz), new Point2(-hx, hz) };
            for (int i = 0; i < corners.Length; i++)
            {
                var p = corners[i];
                corners[i] = new Point2(o.x + c * p.x + s * p.z, o.z - s * p.x + c * p.z);
            }
            return corners;
        }

        // Separating-axis test for oriented, convex footprints. Contact is allowed.
        public static bool Overlaps(Point2[] a, Point2[] b)
        {
            foreach (var polygon in new[] { a, b })
                for (int i = 0; i < polygon.Length; i++)
                {
                    var p = polygon[i]; var q = polygon[(i + 1) % polygon.Length];
                    double ax = -(q.z - p.z), az = q.x - p.x;
                    Project(a, ax, az, out double amin, out double amax);
                    Project(b, ax, az, out double bmin, out double bmax);
                    if (amax <= bmin + 1e-8 || bmax <= amin + 1e-8) return false;
                }
            return true;
        }

        private static void Project(Point2[] points, double x, double z, out double min, out double max)
        {
            min = double.PositiveInfinity; max = double.NegativeInfinity;
            foreach (var p in points)
            {
                double d = p.x * x + p.z * z;
                min = Math.Min(min, d); max = Math.Max(max, d);
            }
        }

        public static double PointSegmentDistance(Point2 p, Point2 a, Point2 b)
        {
            double dx = b.x - a.x, dz = b.z - a.z, length = dx * dx + dz * dz;
            double t = length < 1e-16 ? 0 : Math.Max(0, Math.Min(1, ((p.x - a.x) * dx + (p.z - a.z) * dz) / length));
            double x = p.x - a.x - t * dx, z = p.z - a.z - t * dz;
            return Math.Sqrt(x * x + z * z);
        }

        private static double Cross(Point2 a, Point2 b, Point2 p)
        { return (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x); }

        public static bool Contains(Point2[] polygon, Point2 p)
        {
            bool positive = false, negative = false;
            for (int i = 0; i < polygon.Length; i++)
            {
                double c = Cross(polygon[i], polygon[(i + 1) % polygon.Length], p);
                if (c > 1e-8) positive = true;
                if (c < -1e-8) negative = true;
            }
            return !(positive && negative);
        }

        public static double SegmentDistance(Point2 a, Point2 b, Point2 c, Point2 d)
        {
            double c1 = Cross(a, b, c), c2 = Cross(a, b, d), c3 = Cross(c, d, a), c4 = Cross(c, d, b);
            if (((c1 > 0 && c2 < 0) || (c1 < 0 && c2 > 0)) &&
                ((c3 > 0 && c4 < 0) || (c3 < 0 && c4 > 0))) return 0;
            return Math.Min(Math.Min(PointSegmentDistance(a, c, d), PointSegmentDistance(b, c, d)),
                Math.Min(PointSegmentDistance(c, a, b), PointSegmentDistance(d, a, b)));
        }

        public static double PolygonSegmentDistance(Point2[] polygon, Point2 a, Point2 b)
        {
            if (Contains(polygon, a) || Contains(polygon, b)) return 0;
            double min = double.PositiveInfinity;
            for (int i = 0; i < polygon.Length; i++)
                min = Math.Min(min, SegmentDistance(polygon[i], polygon[(i + 1) % polygon.Length], a, b));
            return min;
        }

        // Membership includes every cell touched by the AABB of a rotated footprint.
        // Conservative over-inclusion at boundaries avoids missing cross-cell references.
        public static List<CellKey> TouchedCells(GridSpec grid, Point2[] footprint)
        {
            double minX = double.PositiveInfinity, maxX = double.NegativeInfinity;
            double minZ = double.PositiveInfinity, maxZ = double.NegativeInfinity;
            foreach (var p in footprint)
            { minX = Math.Min(minX, p.x); maxX = Math.Max(maxX, p.x); minZ = Math.Min(minZ, p.z); maxZ = Math.Max(maxZ, p.z); }
            int countX = (int)Math.Round(grid.sizeX / grid.cellSize), countZ = (int)Math.Round(grid.sizeZ / grid.cellSize);
            int startX = Math.Max(0, (int)Math.Floor((minX - grid.originX) / grid.cellSize));
            int endX = Math.Min(countX - 1, (int)Math.Floor((maxX - grid.originX) / grid.cellSize));
            int startZ = Math.Max(0, (int)Math.Floor((minZ - grid.originZ) / grid.cellSize));
            int endZ = Math.Min(countZ - 1, (int)Math.Floor((maxZ - grid.originZ) / grid.cellSize));
            var result = new List<CellKey>();
            for (int z = startZ; z <= endZ; z++)
                for (int x = startX; x <= endX; x++) result.Add(new CellKey(x, z));
            return result;
        }
    }

    [Serializable]
    public struct CellKey : IEquatable<CellKey>, IComparable<CellKey>
    {
        public int x;
        public int z;
        public CellKey(int x, int z) { this.x = x; this.z = z; }
        public bool Equals(CellKey other) { return x == other.x && z == other.z; }
        public override bool Equals(object obj) { return obj is CellKey other && Equals(other); }
        public override int GetHashCode() { unchecked { return x * 397 ^ z; } }
        public int CompareTo(CellKey other) { int c = z.CompareTo(other.z); return c != 0 ? c : x.CompareTo(other.x); }
        public override string ToString() { return "cell_" + x + "_" + z; }
    }
}
