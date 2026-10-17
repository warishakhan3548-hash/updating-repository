using System;

namespace Aaris.World
{
    // North-up, top-left-origin coordinates. Values can be outside [0, 1]
    // only when the caller explicitly requests an unclamped projection.
    public readonly struct TacticalMapPoint
    {
        public readonly double u, v;
        public readonly bool clipped;
        internal TacticalMapPoint(double u, double v, bool clipped)
        { this.u = u; this.v = v; this.clipped = clipped; }
    }

    public readonly struct TacticalMapCircle
    {
        public readonly TacticalMapPoint center;
        public readonly double radiusU, radiusV;
        internal TacticalMapCircle(TacticalMapPoint center, double radiusU, double radiusV)
        { this.center = center; this.radiusU = radiusU; this.radiusV = radiusV; }
    }

    // Captures bounds once; later source-grid mutations cannot move a cached map.
    public sealed class TacticalMapProjection
    {
        private readonly double minX, minZ, maxX, maxZ, width, depth;

        public TacticalMapProjection(GridSpec grid)
        {
            if (grid == null || !WorldValidator.Finite(grid.originX, grid.originZ, grid.sizeX, grid.sizeZ) ||
                grid.sizeX <= 0 || grid.sizeZ <= 0)
                throw new ArgumentException("Finite positive tactical-map bounds are required.");
            minX = grid.originX; minZ = grid.originZ; width = grid.sizeX; depth = grid.sizeZ;
            maxX = minX + width; maxZ = minZ + depth;
            if (!WorldValidator.Finite(maxX, maxZ) || maxX <= minX || maxZ <= minZ)
                throw new ArgumentException("Tactical-map bounds must be finite and representable.");
        }

        public TacticalMapPoint Project(double x, double z, bool clamp = true)
        {
            if (!WorldValidator.Finite(x, z)) throw new ArgumentException("Finite map coordinates are required.");
            bool outside = x < minX || x > maxX || z < minZ || z > maxZ;
            if (clamp) { x = Math.Max(minX, Math.Min(maxX, x)); z = Math.Max(minZ, Math.Min(maxZ, z)); }
            double u = (x - minX) / width, v = 1 - (z - minZ) / depth;
            if (!WorldValidator.Finite(u, v)) throw new ArgumentException("Map coordinates exceed representable projection range.");
            return new TacticalMapPoint(u, v, clamp && outside);
        }

        // A world circle becomes an ellipse on a rectangular normalized map.
        // Do not clamp its centre: doing so would move an off-map zone inwards.
        public TacticalMapCircle ProjectCircle(double x, double z, double radius)
        {
            if (!WorldValidator.Finite(radius) || radius < 0) throw new ArgumentException("Finite nonnegative map radius is required.");
            var center = Project(x, z, false);
            double ru = radius / width, rv = radius / depth;
            if (!WorldValidator.Finite(ru, rv)) throw new ArgumentException("Map radius exceeds representable projection range.");
            return new TacticalMapCircle(center, ru, rv);
        }
    }

    public readonly struct SafeZoneGuidance
    {
        public readonly Point2 safePoint;
        public readonly double distance, bearing;
        public readonly bool outside;
        internal SafeZoneGuidance(Point2 safePoint, double distance, double bearing)
        { this.safePoint = safePoint; this.distance = distance; this.bearing = bearing; outside = distance > 0; }
    }

    public static class TacticalNavigation
    {
        public static double NormalizeHeading(double degrees)
        {
            if (!WorldValidator.Finite(degrees)) throw new ArgumentException("Finite heading is required.");
            double result = degrees % 360;
            if (result < 0) result += 360;
            return result == 0 || result >= 360 ? 0 : result;
        }

        // Unity yaw: +Z north is 0 degrees; +X east is 90 degrees.
        // Coincident points have a stable zero bearing rather than NaN.
        public static double Bearing(double fromX, double fromZ, double toX, double toZ)
        {
            if (!WorldValidator.Finite(fromX, fromZ, toX, toZ)) throw new ArgumentException("Finite bearing coordinates are required.");
            double dx = toX - fromX, dz = toZ - fromZ;
            if (!WorldValidator.Finite(dx, dz)) throw new ArgumentException("Bearing displacement exceeds representable range.");
            if (dx == 0 && dz == 0) return 0;
            return NormalizeHeading(Math.Atan2(dx, dz) * (180 / Math.PI));
        }

        // Positive turns clockwise. Exactly opposite headings choose -180.
        public static double SignedHeadingDelta(double heading, double targetHeading)
        {
            double delta = NormalizeHeading(targetHeading) - NormalizeHeading(heading);
            if (delta < -180) delta += 360;
            else if (delta >= 180) delta -= 360;
            return delta == 0 ? 0 : delta;
        }

        // Matches BattleZoneSnapshot.ExcessDistance: capsule overlap is tolerated
        // until its centre is beyond zone.radius + capsuleRadius. This is a
        // straight-line distance/bearing, not obstacle-aware pathfinding.
        public static SafeZoneGuidance ToSafeZone(BattleZoneSnapshot zone, double x, double z, double capsuleRadius = 0)
        {
            if (!WorldValidator.Finite(zone.x, zone.z, zone.radius, x, z, capsuleRadius) || zone.radius < 0 || capsuleRadius < 0)
                throw new ArgumentException("Finite zone coordinates and nonnegative radii are required.");
            double safeRadius = zone.radius + capsuleRadius, dx = x - zone.x, dz = z - zone.z;
            if (!WorldValidator.Finite(safeRadius, dx, dz)) throw new ArgumentException("Zone query exceeds representable range.");
            double range = Geometry.PlanarDistance(dx, dz), excess = Math.Max(0, range - zone.radius - capsuleRadius);
            if (excess == 0) return new SafeZoneGuidance(new Point2(x, z), 0, 0);
            double factor = safeRadius / range;
            var safe = new Point2(zone.x + dx * factor, zone.z + dz * factor);
            if (!WorldValidator.Finite(safe.x, safe.z)) throw new ArgumentException("Safe point exceeds representable range.");
            // Rounding a diagonal projection can land infinitesimally outside.
            // Retreat by a sub-micrometre at supported world sizes so the
            // damage query agrees that this representable destination is safe.
            if (zone.Outside(safe.x, safe.z, capsuleRadius))
            {
                factor = Math.Max(0, safeRadius - Math.Max(1, safeRadius) * 1e-12) / range;
                safe = new Point2(zone.x + dx * factor, zone.z + dz * factor);
            }
            return new SafeZoneGuidance(safe, excess, Bearing(x, z, zone.x, zone.z));
        }

    }
}
