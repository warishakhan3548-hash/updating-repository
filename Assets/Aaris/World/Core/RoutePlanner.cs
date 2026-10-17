using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    [Serializable]
    public sealed class RoutePlanOptions
    {
        public double spacing = 8;
        public double clearanceRadius = 2.5;
        public double maxSlopeDegrees = 25;
        public double slopeWeight = 6;
        public int maxNodes = 70000;
        public int maxExpansions = 50000;
    }

    [Serializable]
    public sealed class RouteProposal
    {
        public Point2[] points = Array.Empty<Point2>();
        public int expandedNodes;
        public double length;
        public double weightedCost;
        public double maxSampledSlope;
    }

    // Offline outdoor route proposals, not NavMesh, vehicle simulation or runtime AI.
    // The terrain-weighted shortest-path principle is public research; this is our
    // bounded 8-neighbour A* implementation, without bridges, tunnels or cut/fill.
    public static class RoutePlanner
    {
        public static RouteProposal Plan(WorldSpec world, AssetRegistry registry, Point2 start, Point2 end, RoutePlanOptions options)
        {
            var errors = WorldValidator.Validate(world, registry);
            if (errors.Count > 0) throw new ArgumentException("Route planning requires valid source: " + errors[0]);
            var surface = new Surface(world, registry, options);
            var g = world.grid;
            if (!WorldValidator.Finite(start.x, start.z, end.x, end.z)) throw new ArgumentException("Finite route endpoints are required.");
            int nx = (int)Math.Floor(g.sizeX / options.spacing) + 1, nz = (int)Math.Floor(g.sizeZ / options.spacing) + 1;
            if ((long)nx * nz > options.maxNodes) throw new InvalidOperationException("Route grid exceeds maxNodes. Increase spacing or split the request.");
            Point2 At(int key) => new Point2(g.originX + key % nx * options.spacing, g.originZ + key / nx * options.spacing);
            int Snap(Point2 p) => (int)Math.Round((p.x - g.originX) / options.spacing) + nx * (int)Math.Round((p.z - g.originZ) / options.spacing);
            if (!WorldValidator.Inside(g, start.x, start.z) || !WorldValidator.Inside(g, end.x, end.z)) throw new ArgumentException("Route endpoints must be inside the world.");
            int first = Snap(start), goal = Snap(end);
            // Never silently move an endpoint out of an obstacle to make a path work.
            if (first < 0 || first >= nx * nz || goal < 0 || goal >= nx * nz ||
                !surface.Measure(start, At(first)).clear || !surface.Measure(At(goal), end).clear)
                throw new InvalidOperationException("Endpoint or nearest lattice connector is blocked. Choose open ground or finer spacing.");
            var costs = Enumerable.Repeat(double.PositiveInfinity, nx * nz).ToArray();
            var parent = Enumerable.Repeat(-1, costs.Length).ToArray();
            var closed = new bool[costs.Length];
            var heap = new MinHeap();
            var edges = new Dictionary<long, Segment>();
            // Costs are at least planar distance, so Euclidean distance is admissible.
            double Heuristic(int key) => Distance(At(key), At(goal));
            Segment Edge(int a, int b)
            {
                long key = ((long)Math.Min(a, b) << 32) | (uint)Math.Max(a, b);
                if (!edges.TryGetValue(key, out var value)) { value = surface.Measure(At(a), At(b)); edges.Add(key, value); }
                return value;
            }
            costs[first] = 0; heap.Push(new Entry(first, 0, Heuristic(first)));
            int expanded = 0;
            while (heap.Count > 0)
            {
                var item = heap.Pop(); int current = item.key;
                if (closed[current] || item.cost != costs[current]) continue;
                if (++expanded > options.maxExpansions) throw new InvalidOperationException("Route search exceeded maxExpansions; no partial path was accepted.");
                closed[current] = true;
                if (current == goal) break;
                int x = current % nx, z = current / nx;
                for (int dz = -1; dz <= 1; dz++) for (int dx = -1; dx <= 1; dx++)
                {
                    if ((dx == 0 && dz == 0) || x + dx < 0 || x + dx >= nx || z + dz < 0 || z + dz >= nz) continue;
                    int next = current + dx + dz * nx;
                    if (closed[next]) continue;
                    // Side edges prevent diagonal corner cutting in blocked grid cells.
                    if (dx != 0 && dz != 0 && (!Edge(current, current + dx).clear || !Edge(current, current + dz * nx).clear)) continue;
                    var segment = Edge(current, next);
                    double candidate = costs[current] + segment.cost;
                    if (!segment.clear || candidate >= costs[next]) continue;
                    costs[next] = candidate; parent[next] = current;
                    heap.Push(new Entry(next, candidate, candidate + Heuristic(next)));
                }
            }
            if (!closed[goal]) throw new InvalidOperationException("No route found within the grid and constraints. No world source was changed.");
            var raw = new List<Point2>();
            for (int key = goal; key >= 0; key = parent[key]) raw.Add(At(key));
            raw.Reverse(); raw.Insert(0, start); raw.Add(end);
            // Bounded lookahead; every shortcut rechecks continuous obstacle/water masks
            // and sampled slope. Reject shortcuts that worsen the terrain-weighted cost.
            var prefix = new double[raw.Count];
            for (int i = 1; i < raw.Count; i++) prefix[i] = prefix[i - 1] + surface.Measure(raw[i - 1], raw[i]).cost;
            var points = new List<Point2> { raw[0] };
            for (int i = 0; i < raw.Count - 1;)
            {
                int next = i + 1;
                for (int j = Math.Min(raw.Count - 1, i + 24); j > i + 1; j--)
                {
                    var shortcut = surface.Measure(raw[i], raw[j]);
                    if (shortcut.clear && shortcut.cost <= prefix[j] - prefix[i] + 1e-7) { next = j; break; }
                }
                if (Distance(points[points.Count - 1], raw[next]) > 1e-8) points.Add(raw[next]);
                i = next;
            }
            var result = new RouteProposal { points = points.ToArray(), expandedNodes = expanded };
            for (int i = 1; i < points.Count; i++)
            {
                var segment = surface.Measure(points[i - 1], points[i]);
                if (!segment.clear) throw new InvalidOperationException("Final route verification failed.");
                result.length += Distance(points[i - 1], points[i]); result.weightedCost += segment.cost;
                result.maxSampledSlope = Math.Max(result.maxSampledSlope, segment.slope);
            }
            return result;
        }

        private static double Distance(Point2 a, Point2 b) { double x = a.x - b.x, z = a.z - b.z; return Math.Sqrt(x * x + z * z); }
        private struct Segment { public bool clear; public double cost, slope; }
        private sealed class Obstacle
        {
            public Point2[] polygon;
            public double minX, maxX, minZ, maxZ;
        }
        private sealed class Surface
        {
            private readonly WorldSpec world;
            private readonly RoutePlanOptions options;
            private readonly TerrainSampler terrain;
            private readonly Obstacle[] obstacles;
            public Surface(WorldSpec world, AssetRegistry registry, RoutePlanOptions options)
            {
                if (options == null || !WorldValidator.Finite(options.spacing, options.clearanceRadius, options.maxSlopeDegrees, options.slopeWeight) ||
                    options.spacing < 2 || options.spacing > 128 || options.clearanceRadius < 0.25 || options.clearanceRadius > 32 ||
                    options.maxSlopeDegrees < 0 || options.maxSlopeDegrees > 60 || options.slopeWeight < 0 || options.slopeWeight > 100 ||
                    options.maxNodes < 4 || options.maxNodes > 262144 || options.maxExpansions < 1 || options.maxExpansions > 200000 ||
                    Math.Abs(world.grid.sizeX / options.spacing - Math.Round(world.grid.sizeX / options.spacing)) > 1e-8 ||
                    Math.Abs(world.grid.sizeZ / options.spacing - Math.Round(world.grid.sizeZ / options.spacing)) > 1e-8)
                    throw new ArgumentException("Invalid route options: bounded costs/budgets and spacing dividing the world dimensions are required.");
                this.world = world; this.options = options; terrain = new TerrainSampler(world);
                var assets = registry.assets.ToDictionary(a => a.id, StringComparer.Ordinal);
                obstacles = world.objects.Where(o => assets[o.asset].blocksPlacement).Select(o =>
                {
                    var polygon = Geometry.Footprint(o, assets[o.asset]);
                    return new Obstacle { polygon = polygon, minX = polygon.Min(p => p.x), maxX = polygon.Max(p => p.x), minZ = polygon.Min(p => p.z), maxZ = polygon.Max(p => p.z) };
                }).ToArray();
            }
            public Segment Measure(Point2 a, Point2 b)
            {
                double radius = options.clearanceRadius; var g = world.grid;
                foreach (var p in new[] { a, b })
                    if (p.x < g.originX + radius || p.x > g.originX + g.sizeX - radius || p.z < g.originZ + radius || p.z > g.originZ + g.sizeZ - radius) return default;
                foreach (var lake in world.terrain.lakes)
                {
                    var p = new Point2((a.x - lake.x) / lake.radiusX, (a.z - lake.z) / lake.radiusZ);
                    var q = new Point2((b.x - lake.x) / lake.radiusX, (b.z - lake.z) / lake.radiusZ);
                    // Conservative Minkowski bound for a disk around an elliptical lake.
                    if (Geometry.PointSegmentDistance(new Point2(), p, q) <= 1 + radius / Math.Min(lake.radiusX, lake.radiusZ)) return default;
                }
                double minX = Math.Min(a.x, b.x) - radius, maxX = Math.Max(a.x, b.x) + radius;
                double minZ = Math.Min(a.z, b.z) - radius, maxZ = Math.Max(a.z, b.z) + radius;
                foreach (var obstacle in obstacles)
                    if (obstacle.maxX >= minX && obstacle.minX <= maxX && obstacle.maxZ >= minZ && obstacle.minZ <= maxZ &&
                        Geometry.PolygonSegmentDistance(obstacle.polygon, a, b) <= radius) return default;
                double length = Distance(a, b), step = Math.Min(2, Math.Min(options.spacing, world.terrain.gridSpacing) * 0.5);
                int count = Math.Max(1, (int)Math.Ceiling(length / step));
                double before = terrain.Height(a.x, a.z), slope = 0, ascent = 0;
                for (int i = 0; i <= count; i++)
                {
                    double t = (double)i / count, x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t;
                    double localSlope = terrain.SlopeDegrees(x, z);
                    if (localSlope > options.maxSlopeDegrees + 1e-6) return default;
                    slope = Math.Max(slope, localSlope);
                    double y = terrain.Height(x, z); if (i > 0) ascent += Math.Abs(y - before); before = y;
                }
                return new Segment { clear = true, cost = length + options.slopeWeight * ascent, slope = slope };
            }
        }
        private struct Entry
        {
            public int key; public double cost, priority;
            public Entry(int key, double cost, double priority) { this.key = key; this.cost = cost; this.priority = priority; }
        }
        private sealed class MinHeap
        {
            private readonly List<Entry> values = new List<Entry>();
            public int Count => values.Count;
            private static bool Less(Entry a, Entry b) => a.priority < b.priority || (a.priority == b.priority && a.key < b.key);
            public void Push(Entry item)
            {
                int i = values.Count; values.Add(item);
                while (i > 0) { int p = (i - 1) / 2; if (!Less(item, values[p])) break; values[i] = values[p]; i = p; }
                values[i] = item;
            }
            public Entry Pop()
            {
                var first = values[0]; int last = values.Count - 1; var item = values[last]; values.RemoveAt(last);
                if (last == 0) return first;
                int i = 0;
                while (i * 2 + 1 < last)
                {
                    int child = i * 2 + 1; if (child + 1 < last && Less(values[child + 1], values[child])) child++;
                    if (!Less(values[child], item)) break; values[i] = values[child]; i = child;
                }
                values[i] = item; return first;
            }
        }
    }
}
