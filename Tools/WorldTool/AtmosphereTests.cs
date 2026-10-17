using Aaris.World;

namespace Aaris.Tools;

public static class AtmosphereTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("atmosphere cycle matches daylight at wrap-around", CycleContinuity);
        yield return ("atmosphere twilight darkens without negative lighting", Twilight);
        yield return ("atmosphere samples stay bounded over many cycles", Bounds);
        yield return ("atmosphere refuses invalid or reversed clocks", InvalidClock);
    }

    private static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    private static void Near(double x, double y, double tolerance = 1e-9)
        => Assert(Math.Abs(x - y) <= tolerance, $"{x} differs from {y}.");
    private static void Throws(Action test)
    {
        try { test(); }
        catch (ArgumentException) { return; }
        throw new Exception("Expected invalid atmosphere clock to fail.");
    }

    private static void CycleContinuity()
    {
        var start = AtmosphereTimeline.Sample(0, 720);
        var end = AtmosphereTimeline.Sample(720, 720);
        var next = AtmosphereTimeline.Sample(1440, 720);
        Near(start.sunFactor, 1);
        Near(start.ambientFactor, 1);
        Near(start.fogFactor, 1);
        Near(start.sunPitchOffsetDegrees, 0);
        Near(start.sunFactor, end.sunFactor);
        Near(start.fogFactor, next.fogFactor);
        var before = AtmosphereTimeline.Sample(720 - 0.001, 720);
        Assert(Math.Abs(before.fogFactor - start.fogFactor) < 0.0001, "Lighting snaps at cycle boundary.");
    }

    private static void Twilight()
    {
        var day = AtmosphereTimeline.Sample(0, 720);
        var dusk = AtmosphereTimeline.Sample(360, 720);
        var halfway = AtmosphereTimeline.Sample(180, 720);
        Assert(dusk.darkness > 0.999 && dusk.sunFactor < day.sunFactor
            && dusk.ambientFactor < day.ambientFactor && dusk.skyExposureFactor < day.skyExposureFactor,
            "Dusk does not affect all intended lighting channels.");
        Assert(halfway.duskWarmth > 0.9, "Transition should have golden-hour warmth.");
        Near(day.sunFactor, AtmosphereTimeline.Sample(720, 720).sunFactor);
    }

    private static void Bounds()
    {
        for (int i = 0; i < 2000; i++)
        {
            var f = AtmosphereTimeline.Sample(i * 3.733, 720);
            Assert(f.darkness >= 0 && f.darkness <= 1 &&
                f.duskWarmth >= 0 && f.duskWarmth <= 1 &&
                f.sunFactor >= 0.18 - 1e-10 && f.sunFactor <= 1 &&
                f.ambientFactor >= 0.45 && f.ambientFactor <= 1 &&
                f.skyExposureFactor >= 0.38 && f.skyExposureFactor <= 1 &&
                f.fogFactor >= 1 && f.fogFactor <= 2 &&
                f.sunPitchOffsetDegrees >= -32 && f.sunPitchOffsetDegrees <= 0,
                "Unbounded lighting factor.");
        }
    }

    private static void InvalidClock()
    {
        Throws(() => AtmosphereTimeline.Sample(-0.1, 720));
        Throws(() => AtmosphereTimeline.Sample(double.NaN, 720));
        Throws(() => AtmosphereTimeline.Sample(double.PositiveInfinity, 720));
        Throws(() => AtmosphereTimeline.Sample(0, double.NaN));
        Throws(() => AtmosphereTimeline.Sample(0, 0));
        Throws(() => AtmosphereTimeline.Sample(0, 30));
        Throws(() => AtmosphereTimeline.Sample(0, 8000));
    }
}
