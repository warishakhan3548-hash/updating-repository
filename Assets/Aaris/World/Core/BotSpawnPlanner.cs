using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    /// <summary>
    /// Compile-time-only, repeatable bot spawn selection. No server, mutable RNG,
    /// runtime terrain search, or changes to authored world object identities.
    /// </summary>
    public static class BotSpawnPlanner
    {
        public static SpawnSpec[] Plan(SandboxSpec sandbox, WorldSpec world, AssetRegistry registry)
        {
            if (sandbox == null || sandbox.bots == null || !sandbox.bots.enabled || sandbox.bots.count == 0)
                return Array.Empty<SpawnSpec>();
            var errors = SandboxValidator.Validate(sandbox, world, registry);
            if (errors.Count != 0) throw new ArgumentException(string.Join("; ", errors));
            var terrain = new TerrainSampler(world);
            var assets = registry.assets.ToDictionary(a => a.id, StringComparer.Ordinal);
            var obstacles = world.objects.Where(o => assets[o.asset].blocksPlacement)
                .Select(o => Geometry.Footprint(o, assets[o.asset])).ToArray();
            var blocked = new List<Point2[]>();
            var result = new List<SpawnSpec>(sandbox.bots.count);
            var zone = sandbox.zone;
            double cx = zone != null && zone.enabled ? zone.startX : sandbox.player.x;
            double cz = zone != null && zone.enabled ? zone.startZ : sandbox.player.z;
            double radius = zone != null && zone.enabled ? zone.startRadius * 0.88 :
                Math.Min(world.grid.sizeX, world.grid.sizeZ) * 0.44;
            const double half = 0.48;
            double minGap = sandbox.bots.spawnSeparation;
            for (int i = 1; i <= 8192 && result.Count < sandbox.bots.count; i++)
            {
                double x = cx + radius * (Halton(i, 2) * 2 - 1);
                double z = cz + radius * (Halton(i, 3) * 2 - 1);
                double dx = x - cx, dz = z - cz;
                if (dx * dx + dz * dz > radius * radius) continue;
                double px = x - sandbox.player.x, pz = z - sandbox.player.z;
                if (px * px + pz * pz < 30 * 30) continue;
                var candidate = new SpawnSpec { id = "BOT_" + (result.Count + 1).ToString("D3"),
                    x = x, z = z, yaw = (i * 137.507764) % 360 };
                var footprint = Geometry.Footprint(new ObjectSpec { x = x, z = z },
                    new AssetSpec { width = 2 * half, depth = 2 * half });
                if (footprint.Any(p => !WorldValidator.Inside(world.grid, p.x, p.z)) ||
                    world.terrain.lakes.Any(l => WorldDesign.IntersectsLake(footprint, l)) ||
                    footprint.Any(p => terrain.SlopeDegrees(p.x, p.z) > 25)) continue;
                if (obstacles.Any(f => Geometry.Overlaps(f, footprint)) ||
                    blocked.Any(f => Geometry.Overlaps(f, footprint))) continue;
                if (result.Any(p => (p.x - x) * (p.x - x) + (p.z - z) * (p.z - z) < minGap * minGap))
                    continue;
                // Do not spawn into the original practice props or static targets.
                if (sandbox.props.Any(p => DistanceSquared(p.x, p.z, x, z) < 9) ||
                    sandbox.targets.Any(p => DistanceSquared(p.x, p.z, x, z) < 9)) continue;
                result.Add(candidate);
                blocked.Add(footprint);
            }
            if (result.Count != sandbox.bots.count)
                throw new InvalidOperationException("Unable to place the requested bots safely; reduce count or separation.");
            return result.ToArray();
        }

        private static double DistanceSquared(double ax, double az, double bx, double bz)
            => (ax - bx) * (ax - bx) + (az - bz) * (az - bz);

        private static double Halton(int index, int radix)
        {
            double fraction = 1, value = 0;
            while (index > 0)
            {
                fraction /= radix;
                value += fraction * (index % radix);
                index /= radix;
            }
            return value;
        }
    }
}
