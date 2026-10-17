using System;
using System.Collections.Generic;
using System.Linq;

namespace Aaris.World
{
    [Serializable]
    public sealed class SandboxSpec
    {
        public int schemaVersion = 1;
        public int revision = 1;
        public int fixedHz = 50;
        public int maxCatchUpSteps = 4;
        public double gravity = 9.81;
        public int maxDynamicBodies = 24;
        public MovementSpec movement = new MovementSpec();
        public WeaponSpec weapon = new WeaponSpec();
        public BattleZoneSpec zone = new BattleZoneSpec();
        public LootSpec loot = new LootSpec();
        public SpawnSpec player = new SpawnSpec { id = "PLAYER_LOCAL", x = -100, z = -190, yaw = 180 };
        public PropSpec[] props = Array.Empty<PropSpec>();
        public SpawnSpec[] targets = Array.Empty<SpawnSpec>();
    }

    [Serializable]
    public sealed class MovementSpec
    {
        public double radius = 0.35, height = 1.8, mass = 75;
        public double walkSpeed = 4.5, sprintSpeed = 7.5;
        public double groundAcceleration = 35, airAcceleration = 7;
        public double jumpHeight = 1.2, maxSlope = 48;
        public double coyoteTime = 0.1, jumpBuffer = 0.12;
    }

    [Serializable]
    public sealed class WeaponSpec
    {
        public int magazine = 30, reserve = 120;
        public double roundsPerSecond = 8, reloadSeconds = 1.8;
        public double damage = 25, headMultiplier = 2, range = 180, impactImpulse = 12;
    }

    [Serializable]
    public sealed class BattleZoneSpec
    {
        // Optional in older sandbox files; the checked-in r2 sandbox enables it explicitly.
        public bool enabled;
        public double startX, startZ, endX, endZ;
        public double startRadius = 490, endRadius = 75;
        public double waitSeconds = 45, shrinkSeconds = 220, damagePerSecond = 4;
    }

    [Serializable]
    public sealed class LootSpec
    {
        public bool enabled;
        public int perDistrict = 3, maxPickups = 24, ammunition = 30, healing = 30;
        public double minSpacing = 18, pickupRadius = 1.4;
    }

    [Serializable]
    public class SpawnSpec
    {
        public string id = "";
        public double x, z, yaw;
    }

    [Serializable]
    public sealed class PropSpec : SpawnSpec
    {
        public double sizeX = 1, sizeY = 1, sizeZ = 1, mass = 15, dropHeight = 0.6;
    }

    public static class SandboxValidator
    {
        public static List<string> Validate(SandboxSpec s, WorldSpec w, AssetRegistry registry)
        {
            var errors = new List<string>();
            if (s == null || s.schemaVersion != 1 || s.revision < 1 || s.movement == null || s.weapon == null || s.player == null || s.props == null || s.targets == null)
            { errors.Add("Sandbox schema, revision and every section are required."); return errors; }
            var m = s.movement; var gun = s.weapon;
            bool Range(double value, double min, double max) => WorldValidator.Finite(value) && value >= min && value <= max;
            if (s.fixedHz < 30 || s.fixedHz > 120 || s.maxCatchUpSteps < 1 || s.maxCatchUpSteps > 8 || !Range(s.gravity, 1, 30) ||
                s.maxDynamicBodies < 1 || s.maxDynamicBodies > 64 || s.props.Length + 1 > s.maxDynamicBodies || s.targets.Length > 16)
                errors.Add("Physics step, gravity and body budgets must be bounded; count the player as a dynamic body.");
            if (!Range(m.radius, 0.2, 0.6) || !Range(m.height, 1, 2.5) || m.height < m.radius * 2 + 0.2 || !Range(m.mass, 40, 150) ||
                !Range(m.walkSpeed, 1, 8) || !Range(m.sprintSpeed, m.walkSpeed, 12) || !Range(m.groundAcceleration, 1, 80) ||
                !Range(m.airAcceleration, 0, m.groundAcceleration) || !Range(m.jumpHeight, 0.2, 2.5) || !Range(m.maxSlope, 1, 55) ||
                !Range(m.coyoteTime, 0, 0.2) || !Range(m.jumpBuffer, 0, 0.25)) errors.Add("Invalid capsule or movement limits.");
            if (gun.magazine < 1 || gun.magazine > 100 || gun.reserve < 0 || gun.reserve > 1000 || !Range(gun.roundsPerSecond, 1, Math.Min(20, s.fixedHz)) ||
                !Range(gun.reloadSeconds, 0.3, 10) || !Range(gun.damage, 1, 100) || !Range(gun.headMultiplier, 1, 4) || !Range(gun.range, 5, 500) ||
                !Range(gun.impactImpulse, 0, 50)) errors.Add("Invalid ammunition, cadence, damage or impulse limits.");
            if (s.loot == null) errors.Add("Loot section cannot be null.");
            else if (s.loot.enabled && (s.loot.perDistrict < 1 || s.loot.perDistrict > 8 ||
                s.loot.maxPickups < 1 || s.loot.maxPickups > 48 ||
                s.loot.ammunition < 1 || s.loot.ammunition > 200 ||
                s.loot.healing < 1 || s.loot.healing > 100 ||
                !Range(s.loot.minSpacing, 3, 50) || !Range(s.loot.pickupRadius, 0.8, 2.5)))
                errors.Add("Loot density, rewards, radius and memory/CPU budget must be bounded.");
            if (errors.Count != 0) return errors;
            var sourceErrors = WorldValidator.Validate(w, registry);
            if (sourceErrors.Count != 0) { errors.Add("World must validate before checking sandbox spawns: " + sourceErrors[0]); return errors; }
            if (s.zone != null && s.zone.enabled)
            {
                var z = s.zone;
                bool InWorld(double x, double v) => WorldValidator.Finite(x, v) &&
                    x >= w.grid.originX && x <= w.grid.originX + w.grid.sizeX &&
                    v >= w.grid.originZ && v <= w.grid.originZ + w.grid.sizeZ;
                double shift = Math.Sqrt((z.endX - z.startX) * (z.endX - z.startX) + (z.endZ - z.startZ) * (z.endZ - z.startZ));
                bool CircleInWorld(double x, double v, double radius) =>
                    InWorld(x - radius, v - radius) && InWorld(x + radius, v + radius);
                if (!CircleInWorld(z.startX, z.startZ, z.startRadius) || !CircleInWorld(z.endX, z.endZ, z.endRadius) ||
                    !Range(z.startRadius, 80, 1000) || !Range(z.endRadius, 20, z.startRadius) ||
                    z.endRadius >= z.startRadius ||
                    !Range(z.waitSeconds, 0, 900) || !Range(z.shrinkSeconds, 30, 1800) ||
                    !Range(z.damagePerSecond, 0.1, 100) ||
                    !WorldValidator.Finite(shift) || shift > z.startRadius - z.endRadius + 1e-8 ||
                    Math.Sqrt((s.player.x - z.startX) * (s.player.x - z.startX) +
                              (s.player.z - z.startZ) * (s.player.z - z.startZ)) + m.radius > z.startRadius)
                    errors.Add("Battle zone must start around the player, have bounded timing/damage and shrink through nested circles inside the world.");
            }
            var terrain = new TerrainSampler(w); var assets = registry.assets.ToDictionary(a => a.id);
            var ids = new HashSet<string>(w.objects.Select(o => o.id), StringComparer.Ordinal);
            var reserved = new List<Point2[]>();
            void Spawn(SpawnSpec p, double width, double depth, double limit)
            {
                if (p == null || string.IsNullOrWhiteSpace(p.id) || p.id.Length > 64 || !ids.Add(p.id) || !WorldValidator.Finite(p.x, p.z, p.yaw) || Math.Abs(p.yaw) > 1000000)
                { errors.Add("Spawn IDs must be unique; transforms must be finite."); return; }
                var footprint = Geometry.Footprint(new ObjectSpec { x = p.x, z = p.z, yaw = p.yaw }, new AssetSpec { width = width, depth = depth });
                if (footprint.Any(v => !WorldValidator.Inside(w.grid, v.x, v.z)) || w.terrain.lakes.Any(l => WorldDesign.IntersectsLake(footprint, l)))
                    errors.Add("Spawn crosses bounds or reserved water: " + p.id);
                if (w.objects.Any(o => assets[o.asset].blocksPlacement && Geometry.Overlaps(footprint, Geometry.Footprint(o, assets[o.asset]))) || reserved.Any(f => Geometry.Overlaps(f, footprint)))
                    errors.Add("Spawn intersects another conservative footprint: " + p.id);
                if (footprint.Concat(new[] { new Point2(p.x, p.z) }).Any(v => terrain.SlopeDegrees(v.x, v.z) > limit)) errors.Add("Spawn terrain is too steep: " + p.id);
                reserved.Add(footprint);
            }
            Spawn(s.player, m.radius * 2 + 0.2, m.radius * 2 + 0.2, m.maxSlope);
            foreach (var p in s.props)
            {
                if (p == null || !Range(p.sizeX, 0.25, 3) || !Range(p.sizeY, 0.25, 3) || !Range(p.sizeZ, 0.25, 3) || !Range(p.mass, 1, 150) || !Range(p.dropHeight, 0.2, 3))
                { errors.Add("Physics props require bounded dimensions, mass and drop height."); continue; }
                Spawn(p, p.sizeX + 0.2, p.sizeZ + 0.2, 25);
            }
            foreach (var target in s.targets) Spawn(target, 1, 1, 25);
            return errors;
        }
    }
}
