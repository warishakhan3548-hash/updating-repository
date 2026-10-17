using Aaris.World;

namespace Aaris.Tools;

public static class TacticalTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("north-up tactical map uses asymmetric world bounds and exact corners", Projection);
        yield return ("tactical map clips markers without moving unclamped zone centres", Clipping);
        yield return ("world circles retain independent map-axis radii", CircleProjection);
        yield return ("tactical map captures bounds instead of following mutable source", CapturedBounds);
        yield return ("compass bearings follow Unity north clockwise in every quadrant", Bearings);
        yield return ("compass heading wraps and signed turns cross north continuously", HeadingWrap);
        yield return ("safe-zone guidance uses the same capsule tolerance as damage", CapsuleMargin);
        yield return ("safe-zone destinations are continuous at the moving boundary", BoundaryContinuity);
        yield return ("safe-zone guidance stays radial and safe around every zone angle", RadialGuidance);
        yield return ("tactical projection and navigation reject malformed or nonfinite input", InvalidInputs);
    }

    private static void Assert(bool ok, string message = "Tactical navigation invariant failed.")
    { if (!ok) throw new Exception(message); }
    private static void Near(double actual, double expected, double tolerance = 1e-8)
        => Assert(Math.Abs(actual - expected) <= tolerance, $"{actual} != {expected}");
    private static void Throws(Action action)
    { try { action(); } catch (ArgumentException) { return; } throw new Exception("Expected invalid tactical input rejection."); }
    private static GridSpec Grid() => new GridSpec { originX = -80, originZ = 20, sizeX = 400, sizeZ = 200 };
    private static BattleZoneSnapshot Zone() => new BattleZoneSnapshot { x = 30, z = -40, radius = 20 };

    private static void Projection()
    {
        var p = new TacticalMapProjection(Grid());
        var nw = p.Project(-80, 220); Near(nw.u, 0); Near(nw.v, 0); Assert(!nw.clipped);
        var ne = p.Project(320, 220); Near(ne.u, 1); Near(ne.v, 0); Assert(!ne.clipped);
        var sw = p.Project(-80, 20); Near(sw.u, 0); Near(sw.v, 1); Assert(!sw.clipped);
        var se = p.Project(320, 20); Near(se.u, 1); Near(se.v, 1); Assert(!se.clipped);
        var inner = p.Project(20, 170); Near(inner.u, 0.25); Near(inner.v, 0.25);
    }

    private static void Clipping()
    {
        var p = new TacticalMapProjection(Grid());
        var clamped = p.Project(-120, 260); Near(clamped.u, 0); Near(clamped.v, 0); Assert(clamped.clipped);
        var raw = p.Project(-120, 260, false); Near(raw.u, -0.1); Near(raw.v, -0.2); Assert(!raw.clipped);
        var extreme = p.Project(double.MaxValue, -double.MaxValue); Near(extreme.u, 1); Near(extreme.v, 1); Assert(extreme.clipped);
        var circle = p.ProjectCircle(-120, 260, 20); Near(circle.center.u, -0.1); Near(circle.center.v, -0.2);
    }

    private static void CircleProjection()
    {
        var p = new TacticalMapProjection(Grid());
        var circle = p.ProjectCircle(120, 120, 50);
        Near(circle.center.u, 0.5); Near(circle.center.v, 0.5);
        Near(circle.radiusU, 0.125); Near(circle.radiusV, 0.25);
        Near(p.Project(170, 120).u - circle.center.u, circle.radiusU);
        Near(circle.center.v - p.Project(120, 170).v, circle.radiusV);
        var point = p.ProjectCircle(120, 120, 0); Near(point.radiusU, 0); Near(point.radiusV, 0);
    }

    private static void CapturedBounds()
    {
        var g = Grid(); var p = new TacticalMapProjection(g);
        g.originX = 500; g.originZ = 500; g.sizeX = 1; g.sizeZ = 1;
        var point = p.Project(120, 120); Near(point.u, 0.5); Near(point.v, 0.5);
    }

    private static void Bearings()
    {
        var destinations = new[] { new Point2(0, 1), new Point2(1, 1), new Point2(1, 0), new Point2(1, -1),
            new Point2(0, -1), new Point2(-1, -1), new Point2(-1, 0), new Point2(-1, 1) };
        for (int i = 0; i < destinations.Length; i++)
            Near(TacticalNavigation.Bearing(20, -30, 20 + destinations[i].x, -30 + destinations[i].z), i * 45);
        Near(TacticalNavigation.Bearing(2, 3, 2, 3), 0);
        Near(TacticalNavigation.Bearing(0, 0, 1e200, 1e200), 45);
    }

    private static void HeadingWrap()
    {
        Near(TacticalNavigation.NormalizeHeading(-1), 359); Near(TacticalNavigation.NormalizeHeading(721), 1);
        Near(TacticalNavigation.NormalizeHeading(-720), 0); Near(TacticalNavigation.NormalizeHeading(360), 0);
        Near(TacticalNavigation.NormalizeHeading(-double.Epsilon), 0);
        Near(TacticalNavigation.SignedHeadingDelta(359, 1), 2); Near(TacticalNavigation.SignedHeadingDelta(1, 359), -2);
        Near(TacticalNavigation.SignedHeadingDelta(0, 180), -180); Near(TacticalNavigation.SignedHeadingDelta(180, 0), -180);
        Near(TacticalNavigation.SignedHeadingDelta(-361, 721), 2);
        Near(TacticalNavigation.SignedHeadingDelta(double.MaxValue, double.MaxValue), 0);
    }

    private static void CapsuleMargin()
    {
        var zone = Zone();
        var overlap = TacticalNavigation.ToSafeZone(zone, 50.25, -40, 0.35);
        Assert(!overlap.outside); Near(overlap.distance, 0); Near(overlap.safePoint.x, 50.25); Near(overlap.safePoint.z, -40);
        var east = TacticalNavigation.ToSafeZone(zone, 55, -40, 0.35);
        Assert(east.outside); Near(east.distance, 4.65); Near(east.bearing, 270);
        Near(east.safePoint.x, 50.35); Near(east.safePoint.z, -40);
        Near(east.distance, zone.ExcessDistance(55, -40, 0.35)); Assert(!zone.Outside(east.safePoint.x, east.safePoint.z, 0.35));
        var north = TacticalNavigation.ToSafeZone(zone, 30, 0);
        Near(north.distance, 20); Near(north.safePoint.z, -20); Near(north.bearing, 180);
        var center = TacticalNavigation.ToSafeZone(zone, zone.x, zone.z, 0.35);
        Assert(!center.outside); Near(center.bearing, 0); Near(center.safePoint.x, zone.x);
    }

    private static void BoundaryContinuity()
    {
        var spec = new BattleZoneSpec { startX = 0, startZ = 0, endX = 15, endZ = 10,
            startRadius = 100, endRadius = 30, waitSeconds = 5, shrinkSeconds = 60 };
        for (int i = 0; i <= 60; i++)
        {
            var zone = BattleZoneTimeline.At(spec, 5 + i);
            const double margin = 0.35, epsilon = 1e-6;
            double edge = zone.x + zone.radius + margin;
            var inside = TacticalNavigation.ToSafeZone(zone, edge - epsilon, zone.z, margin);
            var outside = TacticalNavigation.ToSafeZone(zone, edge + epsilon, zone.z, margin);
            Assert(!inside.outside && outside.outside); Near(outside.distance, epsilon);
            Near(inside.safePoint.x, outside.safePoint.x, 2 * epsilon); Near(inside.safePoint.z, outside.safePoint.z);
            Assert(!zone.Outside(outside.safePoint.x, outside.safePoint.z, margin));
        }
    }

    private static void RadialGuidance()
    {
        var zone = Zone(); const double margin = 0.35;
        for (int angle = 0; angle < 360; angle++)
        {
            double radians = angle * Math.PI / 180, dx = Math.Sin(radians), dz = Math.Cos(radians);
            double x = zone.x + dx * 50, z = zone.z + dz * 50;
            var guide = TacticalNavigation.ToSafeZone(zone, x, z, margin);
            Near(guide.distance, 29.65); Near(TacticalNavigation.SignedHeadingDelta(angle + 180, guide.bearing), 0);
            Near(guide.safePoint.x, zone.x + dx * (zone.radius + margin));
            Near(guide.safePoint.z, zone.z + dz * (zone.radius + margin));
            Assert(!zone.Outside(guide.safePoint.x, guide.safePoint.z, margin), "Projected destination remains outside damage boundary.");
            double movedX = x - guide.safePoint.x, movedZ = z - guide.safePoint.z;
            Near(Math.Sqrt(movedX * movedX + movedZ * movedZ), guide.distance);
        }
        var pointZone = new BattleZoneSnapshot { x = 3, z = -2, radius = 0 };
        var point = TacticalNavigation.ToSafeZone(pointZone, 10, 20); Near(point.safePoint.x, 3); Near(point.safePoint.z, -2);
        var hugeZone = new BattleZoneSnapshot { radius = 1e200 };
        var hugeGuide = TacticalNavigation.ToSafeZone(hugeZone, 1.1e200, 0);
        Assert(hugeGuide.outside && !hugeZone.Outside(hugeGuide.safePoint.x, hugeGuide.safePoint.z));
    }

    private static void InvalidInputs()
    {
        Throws(() => new TacticalMapProjection(null));
        foreach (double invalid in new[] { 0d, -1d, double.NaN, double.PositiveInfinity })
        { var grid = Grid(); grid.sizeX = invalid; Throws(() => new TacticalMapProjection(grid)); }
        var unrepresentable = Grid(); unrepresentable.originX = double.MaxValue; unrepresentable.sizeX = 1;
        Throws(() => new TacticalMapProjection(unrepresentable));
        var overflowing = Grid(); overflowing.originZ = double.MaxValue; overflowing.sizeZ = double.MaxValue;
        Throws(() => new TacticalMapProjection(overflowing));
        var p = new TacticalMapProjection(Grid());
        foreach (double invalid in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
        {
            Throws(() => p.Project(invalid, 0)); Throws(() => p.Project(0, invalid)); Throws(() => p.ProjectCircle(0, 0, invalid));
            Throws(() => TacticalNavigation.NormalizeHeading(invalid)); Throws(() => TacticalNavigation.SignedHeadingDelta(0, invalid));
            Throws(() => TacticalNavigation.Bearing(0, 0, invalid, 0)); Throws(() => TacticalNavigation.ToSafeZone(Zone(), invalid, 0));
            var zone = Zone(); zone.radius = invalid; Throws(() => TacticalNavigation.ToSafeZone(zone, 0, 0));
        }
        Throws(() => p.ProjectCircle(0, 0, -1)); Throws(() => TacticalNavigation.ToSafeZone(Zone(), 0, 0, -1));
        var negativeZone = Zone(); negativeZone.radius = -1; Throws(() => TacticalNavigation.ToSafeZone(negativeZone, 0, 0));
        Throws(() => TacticalNavigation.Bearing(-double.MaxValue, 0, double.MaxValue, 0));
        var hugeZone = new BattleZoneSnapshot { x = -double.MaxValue, z = 0, radius = 20 };
        Throws(() => TacticalNavigation.ToSafeZone(hugeZone, double.MaxValue, 0));
        Throws(() => TacticalNavigation.ToSafeZone(Zone(), double.MaxValue, double.MaxValue));
    }
}
