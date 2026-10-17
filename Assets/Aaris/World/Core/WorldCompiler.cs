using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    [Serializable]
    public sealed class WorldPlan
    {
        public string worldId;
        public int revision;
        public int seed;
        public CellPlan[] cells;
        public ResolvedObject[] objects;
    }

    [Serializable]
    public sealed class CellPlan
    {
        public CellKey key;
        public string[] ownedObjects;
        public string[] references;
        public CostEstimate cost;
    }

    [Serializable]
    public sealed class CostEstimate
    {
        public long triangles;
        public long materialSlots;
        public long textureKiB;
        public long colliders;
        public long shadowCasters;
    }

    [Serializable]
    public sealed class ResolvedObject
    {
        public string id;
        public string asset;
        public double x;
        public double y;
        public double z;
        public double yaw;
        public double scale;
        public CellKey owner;
    }

    public static class WorldCompiler
    {
        public static WorldPlan Compile(WorldSpec world, AssetRegistry registry)
        {
            var errors = WorldValidator.Validate(world, registry);
            if (errors.Count > 0) throw new ArgumentException(string.Join("\n", errors));
            return CompileValidated(world, registry);
        }

        // Internal to prevent unchecked JSON from bypassing the validator.
        internal static WorldPlan CompileValidated(WorldSpec world, AssetRegistry registry)
        {
            var g = world.grid;
            var assets = registry.assets.ToDictionary(a => a.id, StringComparer.Ordinal);
            var owned = new Dictionary<CellKey, List<string>>();
            var refs = new Dictionary<CellKey, List<string>>();
            int nx = (int)Math.Round(g.sizeX / g.cellSize), nz = (int)Math.Round(g.sizeZ / g.cellSize);
            for (int z = 0; z < nz; z++)
                for (int x = 0; x < nx; x++)
                { var key = new CellKey(x, z); owned.Add(key, new List<string>()); refs.Add(key, new List<string>()); }
            var resolved = new List<ResolvedObject>();
            var source = world.objects.ToDictionary(o => o.id, StringComparer.Ordinal);
            var terrain = new TerrainSampler(world);
            foreach (var o in world.objects.OrderBy(o => o.id, StringComparer.Ordinal))
            {
                var owner = CellAt(g, o.x, o.z);
                owned[owner].Add(o.id);
                foreach (var cell in Geometry.TouchedCells(g, Geometry.Footprint(o, assets[o.asset]))) refs[cell].Add(o.id);
                double yaw = ((o.yaw % 360) + 360) % 360;
                resolved.Add(new ResolvedObject { id = o.id, asset = o.asset, x = o.x, y = terrain.Height(o.x, o.z) + o.groundOffset,
                    z = o.z, yaw = yaw, scale = o.scale, owner = owner });
            }
            var cells = new List<CellPlan>();
            foreach (var key in owned.Keys.OrderBy(k => k))
            {
                int segments = (int)Math.Round(g.cellSize / world.terrain.gridSpacing);
                var cost = new CostEstimate { triangles = 2L * segments * segments, materialSlots = 1, colliders = 1 };
                var countedTextures = new HashSet<string>(StringComparer.Ordinal);
                foreach (var id in refs[key])
                {
                    var a = assets[source[id].asset];
                    cost.triangles += a.triangles; cost.materialSlots += a.materialSlots;
                    cost.colliders += a.colliders; cost.shadowCasters += a.shadowCasters;
                    if (countedTextures.Add(a.id)) cost.textureKiB += a.textureKiB;
                }
                cells.Add(new CellPlan { key = key, ownedObjects = owned[key].ToArray(), references = refs[key].ToArray(), cost = cost });
            }
            return new WorldPlan { worldId = world.id, revision = world.revision, seed = world.seed, cells = cells.ToArray(), objects = resolved.ToArray() };
        }

        public static CellKey CellAt(GridSpec grid, double x, double z)
        {
            // Clamp max-edge points into the final cell. Negative-world coordinates use floor.
            return new CellKey(Math.Max(0, Math.Min((int)Math.Round(grid.sizeX / grid.cellSize) - 1, (int)Math.Floor((x - grid.originX) / grid.cellSize))),
                Math.Max(0, Math.Min((int)Math.Round(grid.sizeZ / grid.cellSize) - 1, (int)Math.Floor((z - grid.originZ) / grid.cellSize))));
        }
    }

    public static class StreamingPlanner
    {
        // Planning only. An async scene/Addressables loader and owner dependencies are later work.
        // A hard capacity error is safer than silently dropping nearby terrain or collision.
        public static CellKey[] Desired(WorldSpec world, double x, double z, IEnumerable<CellKey> resident)
        {
            if (!WorldValidator.Finite(x, z)) throw new ArgumentException("Non-finite streaming source.");
            var current = new HashSet<CellKey>(resident ?? Array.Empty<CellKey>());
            var g = world.grid; var selected = new List<CellKey>();
            int nx = (int)Math.Round(g.sizeX / g.cellSize), nz = (int)Math.Round(g.sizeZ / g.cellSize);
            for (int iz = 0; iz < nz; iz++)
                for (int ix = 0; ix < nx; ix++)
                {
                    var key = new CellKey(ix, iz);
                    double minX = g.originX + ix * g.cellSize, minZ = g.originZ + iz * g.cellSize;
                    double dx = Math.Max(0, Math.Max(minX - x, x - minX - g.cellSize));
                    double dz = Math.Max(0, Math.Max(minZ - z, z - minZ - g.cellSize));
                    double radius = current.Contains(key) ? world.streaming.unloadRadius : world.streaming.loadRadius;
                    if (dx * dx + dz * dz <= radius * radius) selected.Add(key);
                }
            if (selected.Count > world.streaming.maxResidentCells)
                throw new InvalidOperationException("Streaming budget needs " + selected.Count + " cells, capacity is " + world.streaming.maxResidentCells + ". Tune radii/capacity; no cells were silently dropped.");
            return selected.ToArray();
        }
    }
}
