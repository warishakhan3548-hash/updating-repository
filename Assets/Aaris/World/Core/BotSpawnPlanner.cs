using System;
using System.Collections.Generic;

namespace Aaris.World
{
    // Offline-only configuration. Bot count is independent of the Rigidbody budget.
    [Serializable]
    public sealed class BotSpec
    {
        public bool enabled;
        public int count = 50;
        public int maxCloseSimulated = 12;
        public double nearRange = 85;
        public double moveSpeed = 3.5;
        public double sightRange = 75;
        public double shotInterval = 1.75;
        public double shotDamage = 7;
    }

    // Editor-time deterministic placement. No UnityEngine dependency; validated by the .NET tool.
    public static class BotSpawnPlanner
    {
        public static SpawnSpec[] Generate(WorldSpec world, AssetRegistry registry, SandboxSpec sandbox)
        {
            if (world == null || registry == null || sandbox == null || sandbox.bots == null)
                throw new ArgumentException("World, registry, sandbox and bot settings are required.");
            var bots = sandbox.bots;
            if (!bots.enabled) return Array.Empty<SpawnSpec>();
            if (bots.count < 1 || bots.count > 100 || bots.maxCloseSimulated < 1 ||
                bots.maxCloseSimulated > 24 || bots.maxCloseSimulated > bots.count)
                throw new ArgumentException("Bot count or active AI budget is invalid.");
            var terrain = new TerrainSampler(world);
            var assetIndex = new Dictionary<string, AssetSpec>(StringComparer.Ordinal);
            foreach (var asset in registry.assets) assetIndex.Add(asset.id, asset);
            var occupied = new List<Point2[]>();
            foreach (var obj in world.objects)
                if (assetIndex.TryGetValue(obj.asset, out var asset) && asset.blocksPlacement)
                    occupied.Add(Geometry.Footprint(obj, asset));
            void Reserve(SpawnSpec s, double width)
            {
                occupied.Add(Geometry.Footprint(new ObjectSpec { x = s.x, z = s.z, yaw = s.yaw },
                    new AssetSpec { width = width, depth = width }));
            }
            Reserve(sandbox.player, sandbox.movement.radius * 2 + 3);
            foreach (var target in sandbox.targets) Reserve(target, 2);
            foreach (var prop in sandbox.props) Reserve(prop, Math.Max(prop.sizeX, prop.sizeZ) + 2);
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var obj in world.objects) ids.Add(obj.id);
            ids.Add(sandbox.player.id);
            foreach (var target in sandbox.targets) ids.Add(target.id);
            foreach (var prop in sandbox.props) ids.Add(prop.id);

            var result = new List<SpawnSpec>(bots.count);
            uint seed = unchecked((uint)world.seed * 1664525u + (uint)sandbox.revision * 1013904223u + 1701u);
            if (seed == 0) seed = 1;
            double Next()
            {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
                return (seed & 0x00ffffffu) / 16777216.0;
            }
            for (int attempt = 0; attempt < bots.count * 1500 && result.Count < bots.count; attempt++)
            {
                double x = world.grid.originX + 8 + Next() * (world.grid.sizeX - 16);
                double z = world.grid.originZ + 8 + Next() * (world.grid.sizeZ - 16);
                double px = x - sandbox.player.x, pz = z - sandbox.player.z;
                if (px * px + pz * pz < 35 * 35) continue;
                if (sandbox.zone != null && sandbox.zone.enabled)
                {
                    double dx = x - sandbox.zone.startX, dz = z - sandbox.zone.startZ;
                    double r = sandbox.zone.startRadius - 6;
                    if (dx * dx + dz * dz > r * r) continue;
                }
                if (terrain.SlopeDegrees(x, z) > 25) continue;
                bool wet = false;
                foreach (var lake in world.terrain.lakes)
                {
                    double dx = (x - lake.x) / (lake.radiusX + 3);
                    double dz = (z - lake.z) / (lake.radiusZ + 3);
                    if (dx * dx + dz * dz < 1) { wet = true; break; }
                }
                if (wet) continue;
                bool close = false;
                foreach (var item in result)
                {
                    double dx = x - item.x, dz = z - item.z;
                    if (dx * dx + dz * dz < 9 * 9) { close = true; break; }
                }
                if (close) continue;
                var candidate = Geometry.Footprint(new ObjectSpec { x = x, z = z },
                    new AssetSpec { width = 1.6, depth = 1.6 });
                bool blocked = false;
                foreach (var footprint in occupied)
                    if (Geometry.Overlaps(candidate, footprint)) { blocked = true; break; }
                if (blocked) continue;
                string id = "BOT_" + (result.Count + 1).ToString("D3");
                if (!ids.Add(id)) throw new InvalidOperationException("Bot identity overlaps an authored world object: " + id);
                result.Add(new SpawnSpec { id = id, x = x, z = z, yaw = Next() * 360 });
            }
            if (result.Count != bots.count)
                throw new InvalidOperationException("Map does not have enough safe spawn positions for the requested bots.");
            return result.ToArray();
        }
    }
}
