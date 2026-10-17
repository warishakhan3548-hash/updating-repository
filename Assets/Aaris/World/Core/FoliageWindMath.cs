using System;

namespace Aaris.World
{
    // Render-only wind: stable per tree position, independent of physics and network ticks.
    // The component rotates a canopy pivot; this policy never moves trunk collision.
    public readonly struct FoliageTilt
    {
        public readonly double pitchDegrees;
        public readonly double rollDegrees;

        public FoliageTilt(double pitchDegrees, double rollDegrees)
        {
            this.pitchDegrees = pitchDegrees;
            this.rollDegrees = rollDegrees;
        }
    }

    public static class FoliageWindMath
    {
        public static FoliageTilt Sample(double seconds, double worldX, double worldZ,
            double frequencyHz, double maximumDegrees)
        {
            if (!WorldValidator.Finite(seconds, worldX, worldZ, frequencyHz, maximumDegrees) ||
                seconds < 0 || frequencyHz <= 0 || frequencyHz > 2 || maximumDegrees < 0 || maximumDegrees > 8)
                throw new ArgumentException("Wind requires finite time, coordinates, frequency and a bounded angle.");

            if (maximumDegrees == 0) return new FoliageTilt(0, 0);

            // Multiscale waves break synchronized motion without per-leaf allocations or packets.
            // Coefficients for each axis sum to one, bounding each tilt by maximumDegrees.
            double phase = worldX * 0.019 + worldZ * 0.031;
            double t = 2.0 * Math.PI * frequencyHz * seconds;
            double pitch = 0.65 * Math.Sin(t + phase)
                         + 0.23 * Math.Sin(0.43 * t - 0.71 * phase)
                         + 0.12 * Math.Sin(1.87 * t + 1.19 * phase);
            double roll = 0.61 * Math.Sin(0.77 * t + 1.29 * phase)
                        + 0.28 * Math.Sin(1.21 * t - 0.43 * phase)
                        + 0.11 * Math.Sin(2.10 * t + phase);
            return new FoliageTilt(pitch * maximumDegrees, roll * maximumDegrees);
        }
    }
}
