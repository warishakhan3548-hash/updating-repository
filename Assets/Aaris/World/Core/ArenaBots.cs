using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    [Serializable]
    public sealed class BotMatchSpec
    {
        // Old sandboxes are opt-out. The authored single-player battle match opts in.
        public bool enabled;
        public int count = 50;
        public int seed = 701;
        public double health = 100, speed = 3.6, detectionRange = 90;
        public double attackRange = 48, damage = 8, secondsPerShot = 0.95;
        public int decisionsPerStep = 4;
    }

    public sealed class BotSpawn
    {
        public string id;
        public double x, z, yaw;
    }

    // Engine-independent authoring: stable sparse spawn distribution, never spawn
    // inside authored structures, water, existing sandbox actors or on steep slopes.
    // No world.json writes, Unity dependency, network/server or commercial assets.
    public static class BotSpawnPlanner
    {
        public static BotSpawn[] Generate(WorldSpec world, AssetRegistry registry, SandboxSpec sandbox)
        {
            if (world == null || registry == null || sandbox == null || sandbox.bots == null)
                throw new ArgumentException("Bot planning needs a validated world, registry and sandbox.");
            var config = sandbox.bots;
            if (!config.enabled) return Array.Empty<BotSpawn>();
            if (config.count < 1 || config.count > 100 || world.grid == null || world.terrain == null ||
                world.terrain.lakes == null || world.objects == null || registry.assets == null ||
                sandbox.player == null || sandbox.props == null || sandbox.targets == null)
                throw new ArgumentException("Bot planning requires bounded counts and complete world data.");

            var terrain = new TerrainSampler(world);
            var byAsset = registry.assets.ToDictionary(a => a.id, StringComparer.Ordinal);
            var blocking = world.objects.Where(o => byAsset[o.asset].blocksPlacement)
                .Select(o => Geometry.Footprint(o, byAsset[o.asset])).ToArray();
            var result = new List<BotSpawn>(config.count);
            var footprintAsset = new AssetSpec { width = 1.5, depth = 1.5 };
            const double margin = 2.5, minSpacing = 10;
            double width = world.grid.sizeX - margin * 2;
            double depth = world.grid.sizeZ - margin * 2;
            if (width <= 0 || depth <= 0) throw new ArgumentException("World too small for bots.");
            double phaseX = Fraction((world.seed * 0.000031 + config.seed * 0.61803398875));
            double phaseZ = Fraction((world.seed * 0.000071 + config.seed * 0.41421356237));

            for (int attempt = 1; attempt <= 12000 && result.Count < config.count; attempt++)
            {
                // Halton disperses actors across every district, without random state
                // or clustering 100 colliders into a single combat/physics hotspot.
                double x = Math.Round(world.grid.originX + margin + width * Fraction(Halton(attempt, 2) + phaseX), 3);
                double z = Math.Round(world.grid.originZ + margin + depth * Fraction(Halton(attempt, 3) + phaseZ), 3);
                if (terrain.SlopeDegrees(x, z) > 28 ||
                    Geometry.PlanarDistance(x - sandbox.player.x, z - sandbox.player.z) < 35)
                    continue;
                bool blocked = false;
                foreach (var lake in world.terrain.lakes)
                {
                    double dx = (x - lake.x) / (lake.radiusX + 2);
                    double dz = (z - lake.z) / (lake.radiusZ + 2);
                    if (dx * dx + dz * dz <= 1) { blocked = true; break; }
                }
                if (blocked) continue;
                foreach (var prop in sandbox.props)
                    if (Geometry.PlanarDistance(x - prop.x, z - prop.z) < Math.Max(prop.sizeX, prop.sizeZ) + 4) { blocked = true; break; }
                if (blocked) continue;
                foreach (var target in sandbox.targets)
                    if (Geometry.PlanarDistance(x - target.x, z - target.z) < 5) { blocked = true; break; }
                if (blocked) continue;
                foreach (var previous in result)
                    if (Geometry.PlanarDistance(x - previous.x, z - previous.z) < minSpacing) { blocked = true; break; }
                if (blocked) continue;
                var poly = Geometry.Footprint(new ObjectSpec { x = x, z = z }, footprintAsset);
                if (poly.Any(v => !WorldValidator.Inside(world.grid, v.x, v.z) ||
                    terrain.SlopeDegrees(v.x, v.z) > 35)) continue;
                foreach (var wall in blocking)
                    if (Geometry.Overlaps(poly, wall)) { blocked = true; break; }
                if (blocked) continue;
                result.Add(new BotSpawn { id = "BOT_" + (result.Count + 1).ToString("D3"),
                    x = x, z = z, yaw = (attempt * 137.50776405) % 360 });
            }
            if (result.Count != config.count)
                throw new ArgumentException("Insufficient safe bot spawns: requested " + config.count + ", placed " + result.Count + ".");
            return result.ToArray();
        }

        private static double Fraction(double v) => v - Math.Floor(v);
        private static double Halton(int index, int radix)
        {
            double inv = 1.0 / radix, fraction = inv, value = 0;
            while (index > 0) { value += fraction * (index % radix); index /= radix; fraction *= inv; }
            return value;
        }
    }

    public enum LocalMatchOutcome { Running, Won, Lost }
    public static class LocalMatchRules
    {
        public static LocalMatchOutcome Outcome(int livingBots, double playerHealth)
        {
            if (livingBots < 0 || !WorldValidator.Finite(playerHealth) || playerHealth < 0)
                throw new ArgumentException("Match state must be finite and nonnegative.");
            if (playerHealth <= 0) return LocalMatchOutcome.Lost;
            return livingBots == 0 ? LocalMatchOutcome.Won : LocalMatchOutcome.Running;
        }

        public static bool CanFire(double distance, double range, bool visible, double now, double nextShot)
        {
            return WorldValidator.Finite(distance, range) && WorldValidator.Finite(now, nextShot) &&
                   distance >= 0 && range > 0 && distance <= range && visible && now >= nextShot;
        }
    }
}
