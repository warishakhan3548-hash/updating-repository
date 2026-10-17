using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    // Immutable planning result. An eventual Unity loader must finish loads before releasing cells.
    // This does not load scenes, disable colliders or claim to stream assets at runtime.
    public sealed class StreamingTransition
    {
        public CellKey[] requiredCells;
        public CellKey[] loadOrder;
        public CellKey[] releaseOrder;
        public string[] referencedObjects;
    }

    public static class StreamingTransitionPlanner
    {
        // This is a pure authoring/runtime policy, not a Unity API.
        // All referenced objects are instantiated from their sole OWNER cell, never from reference cells.
        public static StreamingTransition Plan(WorldSpec world, WorldPlan compiled,
            double x, double z, double velocityX, double velocityZ, IEnumerable<CellKey> resident)
        {
            if (world == null || world.grid == null || world.streaming == null || compiled == null ||
                compiled.cells == null || compiled.objects == null)
                throw new ArgumentException("A valid world and compiled cell plan are required.");
            if (!WorldValidator.Finite(x, z, velocityX, velocityZ))
                throw new ArgumentException("Player location and velocity must be finite.");
            if (!string.Equals(compiled.worldId, world.id, StringComparison.Ordinal) ||
                compiled.revision != world.revision || compiled.seed != world.seed)
                throw new InvalidOperationException("Streaming plan and world source revision do not match.");

            var grid = world.grid;
            if (x < grid.originX || x > grid.originX + grid.sizeX ||
                z < grid.originZ || z > grid.originZ + grid.sizeZ)
                throw new ArgumentException("Player position is outside the authored world.");
            int nx = (int)Math.Round(grid.sizeX / grid.cellSize);
            int nz = (int)Math.Round(grid.sizeZ / grid.cellSize);
            var byCell = compiled.cells.ToDictionary(c => c.key);
            var byObject = compiled.objects.ToDictionary(o => o.id, StringComparer.Ordinal);
            if (byCell.Count != nx * nz)
                throw new InvalidOperationException("Compiled cell manifest is incomplete.");

            var loaded = new HashSet<CellKey>();
            foreach (var key in resident ?? Array.Empty<CellKey>())
            {
                if (!InGrid(key, nx, nz) || !byCell.ContainsKey(key))
                    throw new ArgumentException("Resident cells include an invalid cell.");
                loaded.Add(key);
            }

            // Existing hysteresis/budget policy chooses local terrain and reference cells.
            var nearby = StreamingPlanner.Desired(world, x, z, loaded);
            var required = new HashSet<CellKey>(nearby);
            var ownerDependencies = new HashSet<CellKey>();
            var referenced = new HashSet<string>(StringComparer.Ordinal);
            foreach (var key in nearby)
            {
                if (!byCell.TryGetValue(key, out var cell) || cell.references == null)
                    throw new InvalidOperationException("Compiled cell references are missing.");
                foreach (var id in cell.references)
                {
                    if (!byObject.TryGetValue(id, out var item) ||
                        !InGrid(item.owner, nx, nz) || !byCell.ContainsKey(item.owner))
                        throw new InvalidOperationException("Unresolved world object owner: " + id);
                    referenced.Add(id);
                    ownerDependencies.Add(item.owner);
                    required.Add(item.owner);
                }
            }

            // Owner dependencies are one hop from the original visible/physical cells.
            // Do not recursively include references from each owner cell: that can flood the map.
            if (required.Count > world.streaming.maxResidentCells)
                throw new InvalidOperationException("Visible cells plus unique object-owner dependencies need " +
                    required.Count + " resident cells, budget is " + world.streaming.maxResidentCells + ".");

            // Prioritize mandatory object owners, then closest collision, then travel direction.
            // Cap prediction to avoid unlimited lookahead for teleport/velocity spikes.
            double speed = Geometry.PlanarDistance(velocityX, velocityZ);
            double forward = Math.Min(64.0, speed * 0.35);
            double lookX = speed > 0 ? x + velocityX / speed * forward : x;
            double lookZ = speed > 0 ? z + velocityZ / speed * forward : z;
            var loads = required.Where(k => !loaded.Contains(k))
                .OrderBy(k => ownerDependencies.Contains(k) ? 0 : 1)
                .ThenBy(k => DistanceSquared(grid, k, x, z))
                .ThenBy(k => DistanceSquared(grid, k, lookX, lookZ))
                .ThenBy(k => k)
                .ToArray();
            var releases = loaded.Where(k => !required.Contains(k))
                .OrderByDescending(k => DistanceSquared(grid, k, x, z))
                .ThenBy(k => k)
                .ToArray();
            return new StreamingTransition
            {
                requiredCells = required.OrderBy(k => k).ToArray(),
                loadOrder = loads,
                releaseOrder = releases,
                referencedObjects = referenced.OrderBy(id => id, StringComparer.Ordinal).ToArray()
            };
        }

        private static bool InGrid(CellKey key, int nx, int nz)
        {
            return key.x >= 0 && key.x < nx && key.z >= 0 && key.z < nz;
        }

        private static double DistanceSquared(GridSpec grid, CellKey key, double x, double z)
        {
            double minX = grid.originX + key.x * grid.cellSize;
            double minZ = grid.originZ + key.z * grid.cellSize;
            double dx = Math.Max(0, Math.Max(minX - x, x - minX - grid.cellSize));
            double dz = Math.Max(0, Math.Max(minZ - z, z - minZ - grid.cellSize));
            return dx * dx + dz * dz;
        }
    }
}
