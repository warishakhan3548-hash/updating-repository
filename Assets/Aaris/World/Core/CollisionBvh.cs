using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    public readonly struct Point3
    {
        public readonly double x, y, z;
        public Point3(double x, double y, double z) { this.x = x; this.y = y; this.z = z; }
        public double Length => Math.Sqrt(Dot(this, this));
        public static Point3 operator +(Point3 a, Point3 b) => new Point3(a.x + b.x, a.y + b.y, a.z + b.z);
        public static Point3 operator -(Point3 a, Point3 b) => new Point3(a.x - b.x, a.y - b.y, a.z - b.z);
        public static Point3 operator *(Point3 a, double scale) => new Point3(a.x * scale, a.y * scale, a.z * scale);
        public static double Dot(Point3 a, Point3 b) => a.x * b.x + a.y * b.y + a.z * b.z;
        public static Point3 Cross(Point3 a, Point3 b) => new Point3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
        public bool Finite => WorldValidator.Finite(x) && WorldValidator.Finite(y) && WorldValidator.Finite(z);
        public double Axis(int axis) => axis == 0 ? x : axis == 1 ? y : z;
    }

    public readonly struct CollisionTriangle
    {
        public readonly Point3 a, b, c;
        public readonly string owner;
        public CollisionTriangle(Point3 a, Point3 b, Point3 c, string owner) { this.a = a; this.b = b; this.c = c; this.owner = owner; }
    }
    public readonly struct CollisionHit
    {
        public readonly double distance;
        public readonly string owner;
        public CollisionHit(double distance, string owner) { this.distance = distance; this.owner = owner; }
    }

    // Offline exact-source triangle queries, not a replacement for Unity's physics solver.
    // Median BVH, bounded build size, fixed-depth stack, no per-query heap allocation.
    public sealed class CollisionBvh
    {
        private readonly CollisionTriangle[] triangles;
        private readonly List<Node> nodes = new List<Node>();
        public int TriangleCount => triangles.Length;
        private struct Bounds
        {
            public Point3 low, high;
            public static Bounds Empty => new Bounds { low = new Point3(double.PositiveInfinity, double.PositiveInfinity, double.PositiveInfinity), high = new Point3(double.NegativeInfinity, double.NegativeInfinity, double.NegativeInfinity) };
            public void Add(Point3 p)
            { low = new Point3(Math.Min(low.x, p.x), Math.Min(low.y, p.y), Math.Min(low.z, p.z)); high = new Point3(Math.Max(high.x, p.x), Math.Max(high.y, p.y), Math.Max(high.z, p.z)); }
            public bool Hit(Point3 origin, Point3 direction, double distance)
            {
                double near = 0, far = distance;
                for (int axis = 0; axis < 3; axis++)
                {
                    double o = origin.Axis(axis), d = direction.Axis(axis), lo = low.Axis(axis), hi = high.Axis(axis);
                    if (Math.Abs(d) < 1e-14) { if (o < lo - 1e-8 || o > hi + 1e-8) return false; continue; }
                    double a = (lo - o) / d, b = (hi - o) / d;
                    near = Math.Max(near, Math.Min(a, b)); far = Math.Min(far, Math.Max(a, b));
                    if (near > far + 1e-8) return false;
                }
                return true;
            }
        }
        private struct Node { public Bounds bounds; public int start, count, left, right; }
        private sealed class AxisOrder : IComparer<CollisionTriangle>
        {
            private readonly int axis;
            public AxisOrder(int axis) { this.axis = axis; }
            public int Compare(CollisionTriangle a, CollisionTriangle b)
            {
                int result = (a.a.Axis(axis) + a.b.Axis(axis) + a.c.Axis(axis)).CompareTo(b.a.Axis(axis) + b.b.Axis(axis) + b.c.Axis(axis));
                if (result != 0) return result;
                result = string.Compare(a.owner, b.owner, StringComparison.Ordinal); if (result != 0) return result;
                for (int i = 0; i < 3; i++) { result = a.a.Axis(i).CompareTo(b.a.Axis(i)); if (result != 0) return result; }
                return 0;
            }
        }
        private static readonly AxisOrder[] Orders = { new AxisOrder(0), new AxisOrder(1), new AxisOrder(2) };
        public CollisionBvh(IEnumerable<CollisionTriangle> source, int maxTriangles = 500000)
        {
            if (source == null || maxTriangles < 1 || maxTriangles > 1000000) throw new ArgumentException("Bounded triangle source required.");
            triangles = source.Take(maxTriangles + 1).ToArray();
            if (triangles.Length > maxTriangles) throw new InvalidOperationException("Collision review exceeds its triangle budget.");
            foreach (var t in triangles)
                if (!t.a.Finite || !t.b.Finite || !t.c.Finite || string.IsNullOrEmpty(t.owner) || !WorldValidator.Finite(Point3.Cross(t.b - t.a, t.c - t.a).Length) || Point3.Cross(t.b - t.a, t.c - t.a).Length < 1e-10) throw new ArgumentException("Invalid collision triangle.");
            if (triangles.Length > 0) Build(0, triangles.Length);
        }
        private int Build(int start, int count)
        {
            var bounds = Bounds.Empty;
            for (int i = start; i < start + count; i++) { bounds.Add(triangles[i].a); bounds.Add(triangles[i].b); bounds.Add(triangles[i].c); }
            int key = nodes.Count; nodes.Add(default);
            var node = new Node { bounds = bounds, start = start, count = count };
            if (count > 8)
            {
                Point3 extent = bounds.high - bounds.low;
                int axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : extent.y >= extent.z ? 1 : 2;
                Array.Sort(triangles, start, count, Orders[axis]);
                node.count = 0; node.left = Build(start, count / 2); node.right = Build(start + count / 2, count - count / 2);
            }
            nodes[key] = node; return key;
        }
        public bool Raycast(Point3 origin, Point3 direction, double maxDistance, out CollisionHit hit, bool backfaces = false)
        {
            hit = default;
            if (!origin.Finite || !direction.Finite || !WorldValidator.Finite(direction.Length) || !WorldValidator.Finite(maxDistance) || maxDistance <= 0 || direction.Length < 1e-12) throw new ArgumentException("Finite, nonzero bounded ray required.");
            if (nodes.Count == 0) return false;
            direction = direction * (1 / direction.Length);
            double nearest = maxDistance; string owner = null;
            Span<int> stack = stackalloc int[64]; int pending = 1; stack[0] = 0;
            while (pending > 0)
            {
                var node = nodes[stack[--pending]];
                if (!node.bounds.Hit(origin, direction, nearest)) continue;
                if (node.count == 0) { stack[pending++] = node.left; stack[pending++] = node.right; continue; }
                for (int i = node.start; i < node.start + node.count; i++)
                {
                    var t = triangles[i]; Point3 e1 = t.b - t.a, e2 = t.c - t.a, p = Point3.Cross(direction, e2);
                    double determinant = Point3.Dot(e1, p);
                    if (backfaces ? Math.Abs(determinant) < 1e-10 : determinant < 1e-10) continue;
                    double inverse = 1 / determinant; Point3 offset = origin - t.a;
                    double u = Point3.Dot(offset, p) * inverse; if (u < -1e-8 || u > 1 + 1e-8) continue;
                    Point3 q = Point3.Cross(offset, e1); double v = Point3.Dot(direction, q) * inverse;
                    if (v < -1e-8 || u + v > 1 + 1e-8) continue;
                    double distance = Point3.Dot(e2, q) * inverse;
                    if (distance <= 1e-6 || distance > nearest + 1e-8) continue;
                    if (owner == null || distance < nearest - 1e-8 || string.Compare(t.owner, owner, StringComparison.Ordinal) < 0) { nearest = Math.Min(nearest, distance); owner = t.owner; }
                }
            }
            if (owner == null) return false; hit = new CollisionHit(nearest, owner); return true;
        }

        public static CollisionBvh FromWorld(WorldSpec world, AssetRegistry registry, int maxTriangles = 500000)
        {
            var errors = WorldValidator.Validate(world, registry);
            if (errors.Count > 0) throw new ArgumentException("Validate source before collision review: " + errors[0]);
            if (registry.assets.Any(a => string.IsNullOrEmpty(a.archetype) || !string.IsNullOrEmpty(a.prefabPath)))
                throw new InvalidOperationException("Exact collision review needs procedural assets without prefab overrides; inspect external prefabs in Unity.");
            var models = registry.assets.ToDictionary(a => a.id, a => ProceduralArt.Create(a, 0).collision);
            long terrainTriangles = (long)Math.Round(world.grid.sizeX / world.terrain.gridSpacing) * (long)Math.Round(world.grid.sizeZ / world.terrain.gridSpacing) * 2;
            if (terrainTriangles + world.objects.Sum(o => (long)models[o.asset].triangles.Length / 3) > maxTriangles) throw new InvalidOperationException("World collision review exceeds triangle budget; split the region or increase mesh spacing.");
            var terrain = new TerrainSampler(world);
            IEnumerable<CollisionTriangle> Triangles()
            {
                int nx = (int)Math.Round(world.grid.sizeX / world.grid.cellSize), nz = (int)Math.Round(world.grid.sizeZ / world.grid.cellSize);
                for (int z = 0; z < nz; z++) for (int x = 0; x < nx; x++)
                {
                    var cell = new CellKey(x, z); var mesh = WorldGeometry.Terrain(world, cell);
                    foreach (var t in MeshTriangles(mesh, cell.ToString(), v => new Point3(world.grid.originX + x * world.grid.cellSize + v.x, v.y, world.grid.originZ + z * world.grid.cellSize + v.z))) yield return t;
                }
                foreach (var o in world.objects.OrderBy(o => o.id, StringComparer.Ordinal))
                {
                    double yaw = o.yaw * Math.PI / 180, c = Math.Cos(yaw), s = Math.Sin(yaw), y = terrain.Height(o.x, o.z) + o.groundOffset;
                    foreach (var t in MeshTriangles(models[o.asset], o.id, v => new Point3(o.x + (c * v.x + s * v.z) * o.scale, y + v.y * o.scale, o.z + (-s * v.x + c * v.z) * o.scale))) yield return t;
                }
            }
            return new CollisionBvh(Triangles(), maxTriangles);
        }
        public static IEnumerable<CollisionTriangle> MeshTriangles(ArtMesh mesh, string owner, Func<ArtVertex, Point3> transform)
        {
            for (int i = 0; i < mesh.triangles.Length; i += 3)
                yield return new CollisionTriangle(transform(mesh.vertices[mesh.triangles[i]]), transform(mesh.vertices[mesh.triangles[i + 1]]), transform(mesh.vertices[mesh.triangles[i + 2]]), owner);
        }
    }
}
