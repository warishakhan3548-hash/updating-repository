using System;

namespace Aaris.World
{
    // Pure, deterministic visual policy: no Unity API, network clock, particles, or physics.
    // The cycle is continuous at wrap-around so no abrupt light/fog changes occur.
    public readonly struct AtmosphereFrame
    {
        public readonly double darkness;
        public readonly double duskWarmth;
        public readonly double sunFactor;
        public readonly double ambientFactor;
        public readonly double skyExposureFactor;
        public readonly double fogFactor;
        public readonly double sunPitchOffsetDegrees;

        public AtmosphereFrame(double darkness, double duskWarmth, double sunFactor,
            double ambientFactor, double skyExposureFactor, double fogFactor, double sunPitchOffsetDegrees)
        {
            this.darkness = darkness;
            this.duskWarmth = duskWarmth;
            this.sunFactor = sunFactor;
            this.ambientFactor = ambientFactor;
            this.skyExposureFactor = skyExposureFactor;
            this.fogFactor = fogFactor;
            this.sunPitchOffsetDegrees = sunPitchOffsetDegrees;
        }
    }

    public static class AtmosphereTimeline
    {
        public static AtmosphereFrame Sample(double elapsedSeconds, double cycleSeconds)
        {
            if (double.IsNaN(elapsedSeconds) || double.IsInfinity(elapsedSeconds) || elapsedSeconds < 0 ||
                double.IsNaN(cycleSeconds) || double.IsInfinity(cycleSeconds) ||
                cycleSeconds < 120 || cycleSeconds > 7200)
                throw new ArgumentException("Atmosphere clock must be finite, nonnegative, and cycle 120–7200 seconds.");

            double phase = (elapsedSeconds % cycleSeconds) / cycleSeconds;
            // Two smooth half-cycles: daylight -> dusk/low light -> daylight.
            double darkness = Smooth(0.5 - 0.5 * Math.Cos(2 * Math.PI * phase));
            double warmth = 4 * darkness * (1 - darkness);
            // Subtle atmospheric haze; this does not pretend to simulate rain/cloud geometry.
            double haze = Smooth(0.5 - 0.5 * Math.Cos(4 * Math.PI * phase));
            return new AtmosphereFrame(
                darkness,
                warmth,
                1 - 0.82 * darkness,
                1 - 0.55 * darkness,
                1 - 0.62 * darkness,
                1 + 0.75 * darkness + 0.25 * haze,
                -32 * darkness);
        }

        private static double Smooth(double x) => x * x * (3 - 2 * x);
    }
}
