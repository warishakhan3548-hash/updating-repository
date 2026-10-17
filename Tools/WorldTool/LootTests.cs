using System;
using System.Collections.Generic;
using System.Linq;
using Aaris.World;

namespace Aaris.Tools;

// Pure authoring-contract checks. These do not substitute for Unity physics/PlayMode tests.
public static class LootTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("real world loot is bounded, distinct and reproducible", RealWorld);
        yield return ("loot does not depend on object source ordering", ObjectOrder);
        yield return ("changing the world seed changes supply placements", DifferentSeed);
        yield return ("fully blocked district fails instead of ghost-spawning", UnsafeDistrict);
        yield return ("reserve supplies respect 1000-round cap and reset", ReserveBounded);
    }

    private static (WorldSpec w, AssetRegistry a, SandboxSpec s) Sources()
        => (WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath),
            WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath),
            WorldFiles.Read<SandboxSpec>("Assets/GameData/World/sandbox.json"));

    private static void Require(bool yes, string why)
    { if (!yes) throw new Exception(why); }

    private static void RealWorld()
    {
        var (w, a, s) = Sources();
        var first = LootPlanner.Build(w, a, s);
        var second = LootPlanner.Build(w, a, s);
        Require(first.Length == 3 * w.landmarks.Length && first.Length > 0, "One district is missing balanced supplies.");
        Require(first.Select(p => p.id).Distinct(StringComparer.Ordinal).Count() == first.Length, "Duplicate loot ID.");
        for (int i = 0; i < first.Length; i++)
        {
            var p = first[i]; var q = second[i];
            Require(p.id == q.id && p.kind == q.kind && p.amount == q.amount &&
                    p.x == q.x && p.z == q.z && p.y == q.y, "Unstable same-seed spawn.");
            Require(WorldValidator.Inside(w.grid, p.x, p.z), "Supply outside playable map.");
            Require(!w.terrain.lakes.Any(l => WorldDesign.IntersectsLake(
                new[] {new Point2(p.x - .55, p.z - .55), new Point2(p.x + .55, p.z - .55),
                       new Point2(p.x + .55, p.z + .55), new Point2(p.x - .55, p.z + .55)}, l)),
                "Supply overlaps water.");
            Require(p.kind == LootKind.Medkit ? p.amount == 35 : p.amount == 30, "Unknown benefit.");
            for (int j = 0; j < i; j++)
            {
                var d = Geometry.PlanarDistance(p.x - first[j].x, p.z - first[j].z);
                Require(d >= 13, "Two supply locations overlap.");
            }
        }
    }

    private static void ObjectOrder()
    {
        var (w, a, s) = Sources();
        var before = LootPlanner.Build(w, a, s);
        Array.Reverse(w.objects);
        var after = LootPlanner.Build(w, a, s);
        Require(before.Length == after.Length, "Object ordering changed district allocation.");
        for (int i = 0; i < before.Length; i++)
            Require(before[i].x == after[i].x && before[i].z == after[i].z, "Object ordering changed supply coordinates.");
    }

    private static void DifferentSeed()
    {
        var (w, a, s) = Sources();
        var before = LootPlanner.Build(w, a, s);
        w.seed += 1;
        var after = LootPlanner.Build(w, a, s);
        Require(before.Length == after.Length && before.Any(p => after.All(q => p.x != q.x || p.z != q.z)),
            "Distinct seeds yielded identical supplies.");
    }

    private static void UnsafeDistrict()
    {
        var (w, a, s) = Sources();
        // A giant exclusion lake fully engulfs one district's placement search area.
        var l = w.landmarks[0];
        w.terrain.lakes = new[] { new LakeSpec { id = "BLOCKED", x = l.x, z = l.z, radiusX = 180, radiusZ = 180 } };
        try { LootPlanner.Build(w, a, s); }
        catch (InvalidOperationException) { return; }
        throw new Exception("Unsafe map silently accepted a supply placement.");
    }

    private static void ReserveBounded()
    {
        var s = new WeaponSpec { magazine = 30, reserve = 990 };
        var state = new WeaponState(s);
        Require(state.GrantReserve(30) == 10 && state.Reserve == 1000, "Reserve cap broken.");
        Require(state.GrantReserve(30) == 0, "Overflow generated ammunition.");
        try { state.GrantReserve(-1); throw new Exception("Negative grant accepted."); }
        catch (ArgumentOutOfRangeException) { }
        state.Reset();
        Require(state.Reserve == 990, "Reset did not restore authored reserve.");
    }
}
