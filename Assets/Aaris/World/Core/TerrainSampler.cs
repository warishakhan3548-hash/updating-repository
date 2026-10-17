using System;

namespace Aaris.World
{
    public sealed class TerrainSampler
    {
        private readonly WorldSpec world;
        public TerrainSampler(WorldSpec world) { this.world = world; }

        // Must match the triangles used by UnityWorldCompiler: a,c,b and b,c,d.
        // This keeps object foundations on the actual rendered mesh, including cell seams.
        public double Height(double x, double z)
        {
            double step = world.terrain.gridSpacing;
            double gx = (x - world.grid.originX) / step;
            double gz = (z - world.grid.originZ) / step;
            double ix = Math.Floor(gx), iz = Math.Floor(gz);
            double u = gx - ix, v = gz - iz;
            double px = world.grid.originX + ix * step;
            double pz = world.grid.originZ + iz * step;
            double a = VertexHeight(px, pz), b = VertexHeight(px + step, pz);
            double c = VertexHeight(px, pz + step), d = VertexHeight(px + step, pz + step);
            return u + v <= 1 ? a + u * (b - a) + v * (c - a)
                : d + (1 - u) * (c - d) + (1 - v) * (b - d);
        }

        // Smooth, seeded macro-color fields evaluated at authoring time only.
        // No runtime texture fetches or physics/heightfield changes.
        public double SurfaceVariation(double x, double z)
        {
            double local = Noise(x / 37.0, z / 37.0, unchecked(world.seed + 5297));
            double regional = Noise(x / 141.0, z / 141.0, unchecked(world.seed + 11731));
            return 0.91 + 0.075 * local + 0.075 * regional;
        }

        public double SlopeDegrees(double x, double z)
        {
            double h = 0.25;
            double dx = (Height(x + h, z) - Height(x - h, z)) / (2 * h);
            double dz = (Height(x, z + h) - Height(x, z - h)) / (2 * h);
            return Math.Atan(Math.Sqrt(dx * dx + dz * dz)) * 180 / Math.PI;
        }

        public double VertexHeight(double x, double z)
        {
            var t = world.terrain;
            double sum = 0, weight = 1, total = 0, frequency = 1 / t.noiseScale;
            for (int i = 0; i < t.octaves; i++)
            {
                sum += Noise(x * frequency, z * frequency, unchecked(world.seed + i * 1013)) * weight;
                total += weight; frequency *= 2; weight *= 0.5;
            }
            double y = t.baseHeight + t.amplitude * sum / total;
            foreach (var hill in t.hills)
            {
                double dx = (x - hill.x) / hill.radius, dz = (z - hill.z) / hill.radius;
                y += hill.height * Math.Exp(-2 * (dx * dx + dz * dz));
            }
            // Pad order is authored and therefore part of deterministic world input.
            foreach (var pad in t.pads)
            {
                double dx = x - pad.x, dz = z - pad.z;
                double distance = Math.Sqrt(dx * dx + dz * dz);
                double alpha = 1 - Smooth(Clamp((distance - pad.radius) / pad.blend));
                y += (pad.height - y) * alpha;
            }
            foreach (var lake in t.lakes)
            {
                double dx = (x - lake.x) / lake.radiusX, dz = (z - lake.z) / lake.radiusZ;
                double q = Math.Sqrt(dx * dx + dz * dz);
                if (q <= 1) y = lake.surfaceY - lake.depth * (1 - q * q * q * q);
                else if (q < 1 + lake.blend)
                {
                    double alpha = Smooth((q - 1) / lake.blend);
                    y = lake.surfaceY + (y - lake.surfaceY) * alpha;
                }
            }
            return y;
        }

        private static double Noise(double x, double z, int seed)
        {
            int ix = (int)Math.Floor(x), iz = (int)Math.Floor(z);
            double u = Smooth(x - ix), v = Smooth(z - iz);
            double a = Hash(ix, iz, seed), b = Hash(ix + 1, iz, seed);
            double c = Hash(ix, iz + 1, seed), d = Hash(ix + 1, iz + 1, seed);
            return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v;
        }

        private static double Hash(int x, int z, int seed)
        {
            unchecked
            {
                uint n = (uint)x * 374761393u + (uint)z * 668265263u + (uint)seed * 1442695041u;
                n = (n ^ (n >> 13)) * 1274126177u;
                n ^= n >> 16;
                return (n & 0x00ffffff) / 16777215.0;
            }
        }

        private static double Smooth(double x) { return x * x * (3 - 2 * x); }
        private static double Clamp(double x) { return Math.Max(0, Math.Min(1, x)); }
    }
}
