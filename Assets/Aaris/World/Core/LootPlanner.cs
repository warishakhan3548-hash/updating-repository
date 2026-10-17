using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    public enum LootKind { Ammo, Medkit }

    [Serializable]
    public sealed class LootSpawn
    {
        public string id = "";
        public LootKind kind;
        public int amount;
        public double x, y, z;
    }

    // An original deterministic local practice loot director, NOT a server inventory.
    // Builds from authored POIs at editor time; never modifies world.json or object identities.
    public static class LootPlanner
    {
        public static LootSpawn[] Build(WorldSpec world, AssetRegistry registry, SandboxSpec sandbox)
        {
            if (world == null || world.grid == null || world.terrain == null || world.objects == null ||
                world.landmarks == null || registry == null || registry.assets == null ||
                sandbox == null || sandbox.player == null || sandbox.targets == null || sandbox.props == null)
                throw new ArgumentException("Validated world, registry and sandbox data are required.");
            var terrain = new TerrainSampler(world);
            var assets = registry.assets.ToDictionary(a => a.id, StringComparer.Ordinal);
            var obstacles = world.objects.Where(o => assets[o.asset].blocksPlacement)
                .Select(o => Geometry.Footprint(o, assets[o.asset])).ToArray();
            var results = new List<LootSpawn>(world.landmarks.Length * 3);
            var landmarks = world.landmarks.OrderBy(l => l.id, StringComparer.Ordinal);
            foreach (var landmark in landmarks)
            {
                if (landmark == null || landmark.radius < 12 || !WorldValidator.Finite(landmark.x, landmark.z, landmark.radius))
                    throw new ArgumentException("Landmark positions and radii must be finite and positive.");
                uint state = StableSeed(world.seed, landmark.id);
                int selected = 0;
                for (int attempt = 0; attempt < 192 && selected < 3; attempt++)
                {
                    // Uniform-area annulus, stable across process launches and object-list permutations.
                    double angle = 2 * Math.PI * Unit(state, attempt * 2 + 1);
                    double radius = Math.Min(landmark.radius * 0.75, 72) *
                                    Math.Sqrt(0.08 + 0.92 * Unit(state, attempt * 2 + 2));
                    double x = landmark.x + radius * Math.Cos(angle);
                    double z = landmark.z + radius * Math.Sin(angle);
                    const double half = 0.55;
                    var footprint = new[]
                    {
                        new Point2(x - half, z - half), new Point2(x + half, z - half),
                        new Point2(x + half, z + half), new Point2(x - half, z + half)
                    };
                    if (footprint.Any(p => !WorldValidator.Inside(world.grid, p.x, p.z))) continue;
                    if (world.terrain.lakes.Any(l => WorldDesign.IntersectsLake(footprint, l))) continue;
                    if (terrain.SlopeDegrees(x, z) > 20) continue;
                    if (obstacles.Any(o => Geometry.Overlaps(footprint, o))) continue;
                    if (results.Any(p => Distance(x, z, p.x, p.z) < 13)) continue;
                    if (Distance(x, z, sandbox.player.x, sandbox.player.z) < 5 ||
                        sandbox.props.Any(p => Distance(x, z, p.x, p.z) < 3) ||
                        sandbox.targets.Any(p => Distance(x, z, p.x, p.z) < 3)) continue;
                    if (sandbox.zone != null && sandbox.zone.enabled &&
                        Distance(x, z, sandbox.zone.startX, sandbox.zone.startZ) + 1 > sandbox.zone.startRadius) continue;
                    bool heal = selected == 0;
                    results.Add(new LootSpawn
                    {
                        id = "LOOT_" + landmark.id + "_" + selected,
                        kind = heal ? LootKind.Medkit : LootKind.Ammo,
                        amount = heal ? 35 : 30,
                        x = x, y = terrain.Height(x, z) + 0.55, z = z
                    });
                    selected++;
                }
                if (selected != 3)
                    throw new InvalidOperationException("No safe loot layout for district " + landmark.id +
                        ". Modify the authoring source rather than placing supplies in collisions or water.");
            }
            return results.ToArray();
        }

        private static double Distance(double x, double z, double otherX, double otherZ)
        {
            double dx = x - otherX, dz = z - otherZ;
            return Math.Sqrt(dx * dx + dz * dz);
        }

        private static uint StableSeed(int seed, string id)
        {
            unchecked
            {
                uint hash = 2166136261u ^ (uint)seed;
                foreach (char ch in id ?? "") hash = (hash ^ ch) * 16777619u;
                return hash;
            }
        }

        private static double Unit(uint seed, int ordinal)
        {
            unchecked
            {
                uint v = seed ^ ((uint)ordinal * 0x9e3779b9u);
                v ^= v >> 16; v *= 0x7feb352du; v ^= v >> 15;
                v *= 0x846ca68bu; v ^= v >> 16;
                return (v & 0xffffffu) / 16777216.0;
            }
        }
    }
}
