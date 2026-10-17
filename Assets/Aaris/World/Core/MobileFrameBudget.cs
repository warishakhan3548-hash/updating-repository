using System;

namespace Aaris.World
{
    // Pure C# policy: Unity-specific rendering changes belong to the runtime adapter.
    // Do not confuse render frame time with GPU time or measured device performance.
    public sealed class MobileFrameBudget
    {
        private const double SlowRatio = 1.18;
        private const double RecoveryRatio = 1.05;
        private double average, slowSeconds, fastSeconds, sinceChange;
        private bool sampled;
        public int TargetFps { get; }
        public int Tier { get; private set; } // 0 = best quality, 3 = lowest allowed quality
        public double AverageFrameSeconds => average;

        public MobileFrameBudget(int targetFps = 60)
        {
            if (targetFps < 30 || targetFps > 120) throw new ArgumentOutOfRangeException(nameof(targetFps));
            TargetFps = targetFps;
        }

        public void Reset()
        {
            average = slowSeconds = fastSeconds = sinceChange = 0;
            sampled = false;
            Tier = 0;
        }

        // Returns true only when a quality tier actually changes. No heap allocation.
        public bool Observe(double frameSeconds)
        {
            // Ignore lifecycle stalls, pauses, zero-length and corrupted samples.
            if (double.IsNaN(frameSeconds) || double.IsInfinity(frameSeconds) ||
                frameSeconds < 0.001 || frameSeconds > 0.5) return false;
            // Winsorize isolated stalls before the moving average. Sustained slow
            // frames still accumulate, but a single GC hitch cannot downgrade art.
            double budget = 1.0 / TargetFps;
            double observed = Math.Min(frameSeconds, budget * 2.5);
            double alpha = 1 - Math.Exp(-observed / 0.5);
            average = sampled ? average + (observed - average) * alpha : observed;
            sampled = true;
            sinceChange += observed;
            if (average > budget * SlowRatio)
            {
                slowSeconds += observed;
                fastSeconds = 0;
            }
            else if (average <= budget * RecoveryRatio)
            {
                fastSeconds += observed;
                slowSeconds = 0;
            }
            else
            {
                slowSeconds = 0;
                fastSeconds = 0;
            }

            if (Tier < 3 && sinceChange >= 2 && slowSeconds >= 1.5)
            {
                Tier++;
                sinceChange = slowSeconds = fastSeconds = 0;
                return true;
            }
            // Conservative restoration prevents constantly toggling quality near the FPS target.
            if (Tier > 0 && sinceChange >= 9 && fastSeconds >= 9)
            {
                Tier--;
                sinceChange = slowSeconds = fastSeconds = 0;
                return true;
            }
            return false;
        }

        public double RenderScale(int shortEdgePixels)
        {
            if (shortEdgePixels <= 0) throw new ArgumentOutOfRangeException(nameof(shortEdgePixels));
            double proposed = Tier == 0 ? 1 : Tier == 1 ? 0.91 : Tier == 2 ? 0.82 : 0.74;
            // Respect a 540-pixel short-edge target whenever the native display allows it.
            return Math.Max(proposed, Math.Min(1, 540.0 / shortEdgePixels));
        }
        public double LodMultiplier => Tier == 0 ? 1 : Tier == 1 ? 0.93 : Tier == 2 ? 0.84 : 0.75;
        public double ShadowDistanceMetres => Tier == 0 ? double.PositiveInfinity :
            Tier == 1 ? 65 : Tier == 2 ? 50 : 35;
    }
}
