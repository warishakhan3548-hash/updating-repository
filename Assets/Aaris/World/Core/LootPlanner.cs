using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    public enum LootKind { Ammunition, Medical }

    // Authoring-time, seed-locked local-practice loot layout. No Unity dependency,
    // dynamic physics bodies, alternate world file or hidden random generator.
    public sealed class LootDrop
    {
        public string id;
        public string districtId;
        public LootKind kind;
        public double x, z;
    }

    public static class LootPlanner
    {
        // Only the static authoring compiler calls this. A server-owned match loot
        // service will be needed before this is suitable for network multiplayer.
        public static LootDrop[] Generate(WorldSpec world, AssetRegistry registry, SandboxSpec sandbox)
        {
            if (world == null || registry == null || sandbox == null || sandbox.loot == null)
                throw new ArgumentException("Validated world, assets and sandbox loot settings are required.");
            if (!sandbox.loot.enabled) return Array.Empty<LootDrop>();
            // The editor compiler already runs the full world/sandbox validators.
            // Avoid an expensive second world-wide validation here, which can
            // also be sensitive to authoring traversal order in layout reports.
            if (world.grid == null || world.terrain == null || world.terrain.lakes == null ||
                world.objects == null || world.landmarks == null || registry.assets == null ||
                sandbox.player == null || sandbox.props == null || sandbox.targets == null ||
                sandbox.loot.maxPickups < 1 || sandbox.loot.maxPickups > 48 ||
                sandbox.loot.perDistrict < 1 || sandbox.loot.perDistrict > 8 ||
                !WorldValidator.Finite(sandbox.loot.minSpacing, sandbox.loot.pickupRadius) ||
                sandbox.loot.minSpacing < 3 || sandbox.loot.minSpacing > 50 ||
                sandbox.loot.pickupRadius < 0.8 || sandbox.loot.pickupRadius > 2.5)
                throw new ArgumentException("Loot planner requires validated source and bounded tuning.");

            var policy = sandbox.loot;
            var terrain = new TerrainSampler(world);
            var assetById = registry.assets.ToDictionary(a => a.id, StringComparer.Ordinal);
            var blocked = world.objects
                .Where(o => assetById[o.asset].blocksPlacement)
                .Select(o => Geometry.Footprint(o, assetById[o.asset]))
                .ToArray();
            var drops = new List<LootDrop>(policy.maxPickups);
            var footprintAsset = new AssetSpec { width = 2.4, depth = 2.4 };

            bool Place(string id, string district, LootKind kind, double x, double z)
            {
                if (drops.Count >= policy.maxPickups) return false;
                // Quantize before geometry checks so checks and authored output agree.
                x = Math.Round(x, 3); z = Math.Round(z, 3);
                const double margin = 1.5;
                if (!WorldValidator.Inside(world.grid, x - margin, z - margin) ||
                    !WorldValidator.Inside(world.grid, x + margin, z + margin) ||
                    terrain.SlopeDegrees(x, z) > 25) return false;
                foreach (var lake in world.terrain.lakes)
                {
                    double dx = (x - lake.x) / (lake.radiusX + margin);
                    double dz = (z - lake.z) / (lake.radiusZ + margin);
                    if (dx * dx + dz * dz <= 1) return false;
                }
                if (Geometry.PlanarDistance(x - sandbox.player.x, z - sandbox.player.z) < 4) return false;
                foreach (var p in sandbox.props)
                    if (Geometry.PlanarDistance(x - p.x, z - p.z) < 3 + Math.Max(p.sizeX, p.sizeZ)) return false;
                foreach (var p in sandbox.targets)
                    if (Geometry.PlanarDistance(x - p.x, z - p.z) < 4) return false;
                foreach (var previous in drops)
                    if (Geometry.PlanarDistance(x - previous.x, z - previous.z) < policy.minSpacing) return false;
                var polygon = Geometry.Footprint(new ObjectSpec { x = x, z = z }, footprintAsset);
                foreach (var wall in blocked)
                    if (Geometry.Overlaps(polygon, wall)) return false;
                drops.Add(new LootDrop { id = id, districtId = district, kind = kind,
                    x = Math.Round(x, 3), z = Math.Round(z, 3) });
                return true;
            }

            // One starter pickup in open ground, so the feature can be verified
            // without travelling across the entire 1km practice island.
            uint startHash = Hash(world.seed, sandbox.player.id);
            for (int attempt = 0; attempt < 64; attempt++)
            {
                double angle = (startHash % 360) * Math.PI / 180 + attempt * 2.399963229728653;
                double radius = 9 + attempt % 4 * 3;
                if (Place("LOOT_START_AMMO", "", LootKind.Ammunition,
                    sandbox.player.x + radius * Math.Cos(angle),
                    sandbox.player.z + radius * Math.Sin(angle))) break;
            }

            // Canonical district order and stable hashing make placement invariant
            // to source array order. Separate districts produce meaningful
            // looting routes without increasing the authored object count.
            foreach (var district in world.landmarks.OrderBy(p => p.id, StringComparer.Ordinal))
            {
                uint hash = Hash(world.seed, district.id);
                int accepted = 0;
                for (int attempt = 0; attempt < 128 && accepted < policy.perDistrict && drops.Count < policy.maxPickups; attempt++)
                {
                    double angle = (hash % 360) * Math.PI / 180 + attempt * 2.399963229728653;
                    double radius = Math.Min(district.radius - 5, 18 + attempt % 9 * 8);
                    if (radius <= 0) break;
                    var kind = accepted % 3 == 0 ? LootKind.Medical : LootKind.Ammunition;
                    if (Place("LOOT_" + district.id + "_" + (accepted + 1).ToString("D2"),
                        district.id, kind, district.x + radius * Math.Cos(angle),
                        district.z + radius * Math.Sin(angle))) accepted++;
                }
            }
            return drops.ToArray();
        }

        private static uint Hash(int seed, string text)
        {
            unchecked
            {
                uint state = 2166136261u ^ (uint)seed;
                foreach (char c in text ?? "") { state ^= c; state *= 16777619; }
                return state;
            }
        }
    }
}
