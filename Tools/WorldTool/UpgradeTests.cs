using Aaris.World;

namespace Aaris.Tools;

public static class UpgradeTests
{
    public static IEnumerable<(string name, Action body)> Cases()
    {
        yield return ("v2 rejects null features before sampling terrain", NullFeatures);
        yield return ("v2 world cannot be silently interpreted as v1", VersionGuard);
        yield return ("district population floor prevents empty settlements", EmptyDistrict);
        yield return ("world building cap prevents map-wide house spam", BuildingCap);
        yield return ("unassigned buildings cannot fill countryside", DistrictBounds);
        yield return ("biome tree minimum is enforced", BiomePopulation);
        yield return ("reserved walking corridors cannot be blocked", BlockedRoute);
        yield return ("district graph requires connectivity", Disconnected);
        yield return ("route graph rejects a single point of failure", Redundancy);
        yield return ("cyclic district routes survive one missing connection", ConnectedCycle);
        yield return ("cover gaps are measured along routes", CoverGap);
        yield return ("lake intersection catches a polygon surrounding water", WaterFootprint);
        yield return ("lake bed lies below water and terrain seams remain continuous", LakeTerrain);
        yield return ("roads cannot cross water without a crossing design", RoadWater);
        yield return ("procedural meshes have valid finite nondegenerate triangles", MeshValidity);
        yield return ("procedural art stays inside registered bounds", MeshBounds);
        yield return ("LOD triangle counts decrease without changing source identity", MeshLods);
        yield return ("trees collide only on trunks, not the entire canopy", TreeCollision);
        yield return ("house collision has an actual central front doorway", Doorway);
        yield return ("procedural material data is repeatable and tileable", Materials);
        yield return ("terrain and water triangles face upward", GroundWinding);
        yield return ("seeded macro terrain tint is deterministic and cell-seam safe", MacroTint);
        yield return ("v2 registry budgets match generated mesh geometry", ArtCosts);
        yield return ("road junction union has the correct surface area", RoadUnionArea);
        yield return ("road junctions have a single surface without holes", RoadUnionCoverage);
        yield return ("unsafe procedural architecture dimensions are rejected", ArtDimensions);
        yield return ("texture budgets follow the configured render resolution", TextureBudget);
    }

    private static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static (WorldSpec w, AssetRegistry a) Fixture()
    {
        return (new WorldSpec { schemaVersion = 2, id = "DesignTest", terrain = new TerrainSpec { amplitude = 0 }, design = new DesignSpec { enabled = true, minLandmarkSeparation = 40 },
            objects = Array.Empty<ObjectSpec>(), landmarks = new[] { new LandmarkSpec { id = "TownA", name = "Town A", x = -80, z = 0, radius = 90 }, new LandmarkSpec { id = "TownB", name = "Town B", x = 80, z = 0, radius = 90 } } },
            new AssetRegistry { schemaVersion = 2, assets = new[] { new AssetSpec { id = "house", archetype = "house", previewShape = "building", providesCover = true } } });
    }
    private static void Has(WorldSpec w, AssetRegistry a, string code)
    { var errors = WorldValidator.Validate(w, a); Assert(errors.Any(e => e.code == code), "Missing " + code + ": " + string.Join("\n", errors)); }
    private static RouteSpec Link(string id, LandmarkSpec a, LandmarkSpec b)
        => new() { id = id, from = a.id, to = b.id, points = new[] { new Point2(a.x, a.z), new Point2(b.x, b.z) }, maxCoverGap = 250 };
    private static void NullFeatures()
    { var (w, a) = Fixture(); w.terrain.hills = null; Has(w, a, "DESIGN_SPEC"); }
    private static void VersionGuard()
    { var (w, a) = Fixture(); w.schemaVersion = 1; Has(w, a, "SCHEMA_VERSION"); }
    private static void EmptyDistrict()
    { var (w, a) = Fixture(); w.landmarks[0].minBuildings = 2; Has(w, a, "DISTRICT_DENSITY"); }
    private static void BuildingCap()
    {
        var (w, a) = Fixture(); w.design.maxTotalBuildings = 1;
        w.objects = new[] { new ObjectSpec { id = "A", asset = "house", x = -80, z = -30, landmark = "TownA" }, new ObjectSpec { id = "B", asset = "house", x = 80, z = -30, landmark = "TownB" } };
        Has(w, a, "WORLD_DENSITY");
    }
    private static void DistrictBounds()
    { var (w, a) = Fixture(); w.objects = new[] { new ObjectSpec { id = "A", asset = "house", x = 300, z = 300 } }; Has(w, a, "DISTRICT_BOUNDS"); }
    private static void BiomePopulation()
    { var (w, a) = Fixture(); w.biomes = new[] { new BiomeSpec { id = "Forest", minTrees = 1 } }; Has(w, a, "BIOME_DENSITY"); }
    private static void BlockedRoute()
    {
        var (w, a) = Fixture(); w.routes = new[] { Link("Link", w.landmarks[0], w.landmarks[1]) };
        w.objects = new[] { new ObjectSpec { id = "A", asset = "house", landmark = "TownA" } }; Has(w, a, "ROUTE_BLOCKED");
    }
    private static void Disconnected() { var (w, a) = Fixture(); Has(w, a, "ROUTE_CONNECTIVITY"); }
    private static void Redundancy()
    { var (w, a) = Fixture(); w.routes = new[] { Link("Link", w.landmarks[0], w.landmarks[1]) }; Has(w, a, "ROUTE_REDUNDANCY"); }
    private static void ConnectedCycle()
    {
        var (w, a) = Fixture(); w.landmarks = w.landmarks.Concat(new[] { new LandmarkSpec { id = "TownC", name = "Town C", x = 0, z = 80 } }).ToArray();
        w.routes = new[] { Link("AB", w.landmarks[0], w.landmarks[1]), Link("BC", w.landmarks[1], w.landmarks[2]), Link("CA", w.landmarks[2], w.landmarks[0]) };
        var errors = WorldValidator.Validate(w, a); Assert(errors.Count == 0, string.Join("\n", errors));
    }
    private static void CoverGap()
    { var (w, a) = Fixture(); w.routes = new[] { Link("Link", w.landmarks[0], w.landmarks[1]) }; w.routes[0].maxCoverGap = 30; Has(w, a, "ROUTE_COVER"); }
    private static void WaterFootprint()
    {
        var (w, a) = Fixture(); a.assets[0].width = a.assets[0].depth = 40;
        w.terrain.lakes = new[] { new LakeSpec { id = "Lake", radiusX = 10, radiusZ = 10 } };
        w.objects = new[] { new ObjectSpec { id = "A", asset = "house" } }; Has(w, a, "WATER_PLACEMENT");
    }
    private static void LakeTerrain()
    {
        var (w, _) = Fixture(); w.terrain.lakes = new[] { new LakeSpec { id = "Lake", surfaceY = 5, depth = 4, radiusX = 40, radiusZ = 40 } };
        var t = new TerrainSampler(w); Assert(t.Height(0, 0) < 2, "Lake centre should be below water.");
        Assert(Math.Abs(t.Height(0.00001, 8) - t.Height(-0.00001, 8)) < 0.001, "Water modifier breaks a terrain seam.");
    }
    private static void RoadWater()
    {
        var (w, a) = Fixture(); w.terrain.lakes = new[] { new LakeSpec { id = "Lake" } };
        w.roads = new[] { new RoadSpec { id = "Road", points = new[] { new Point2(-100, 0), new Point2(100, 0) } } }; Has(w, a, "ROAD_WATER");
    }
    private static AssetSpec[] Catalog() => WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath).assets.Where(a => a.archetype.Length > 0).ToArray();
    private static void MeshValidity()
    {
        foreach (var asset in Catalog()) for (int lod = 0; lod < 3; lod++)
            foreach (var mesh in ProceduralArt.Create(asset, lod).parts)
            {
                Assert(mesh.vertices.All(v => WorldValidator.Finite(v.x, v.y, v.z, v.u, v.v)), asset.id + " has invalid vertices.");
                Assert(mesh.triangles.Length % 3 == 0 && mesh.triangles.All(i => i >= 0 && i < mesh.vertices.Length), asset.id + " has invalid indices.");
                for (int i = 0; i < mesh.triangles.Length; i += 3)
                {
                    var a = mesh.vertices[mesh.triangles[i]]; var b = mesh.vertices[mesh.triangles[i + 1]]; var c = mesh.vertices[mesh.triangles[i + 2]];
                    double ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z, vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z;
                    double area = Math.Pow(uy * vz - uz * vy, 2) + Math.Pow(uz * vx - ux * vz, 2) + Math.Pow(ux * vy - uy * vx, 2);
                    Assert(area > 1e-12, asset.id + " contains a degenerate triangle at LOD " + lod);
                }
            }
    }
    private static void MeshBounds()
    {
        foreach (var asset in Catalog()) for (int lod = 0; lod < 3; lod++)
            foreach (var v in ProceduralArt.Create(asset, lod).parts.SelectMany(p => p.vertices))
                Assert(Math.Abs(v.x) <= asset.width / 2 + 0.03 && Math.Abs(v.z) <= asset.depth / 2 + 0.03 && v.y >= -0.03 && v.y <= asset.height + 0.03, asset.id + " exceeds registered bounds at LOD " + lod);
    }
    private static void MeshLods()
    {
        foreach (var asset in Catalog())
        {
            int[] counts = Enumerable.Range(0, 3).Select(l => ProceduralArt.Create(asset, l).TriangleCount).ToArray();
            Assert(counts[0] >= counts[1] && counts[1] >= counts[2] && counts[2] > 0, asset.id + " LODs do not reduce geometry.");
        }
    }
    private static void TreeCollision()
    {
        foreach (var a in Catalog().Where(a => a.previewShape == "tree"))
        {
            var collider = ProceduralArt.Create(a, 0).collision;
            Assert(collider.vertices.Length > 0 && collider.vertices.All(v => Math.Abs(v.x) < a.width * 0.1 && Math.Abs(v.z) < a.width * 0.1), "Canopy is unexpectedly collidable.");
        }
    }
    private static void Doorway()
    {
        foreach (var a in Catalog().Where(a => a.previewShape == "building"))
        {
            var collision = ProceduralArt.Create(a, 0).collision;
            // Inspect front wall triangles in the central walking opening at standing height.
            bool obstruction = false;
            for (int i = 0; i < collision.vertices.Length; i += 3)
            {
                var tri = collision.vertices.Skip(i).Take(3).ToArray();
                if (tri.All(v => v.z > a.depth / 2 - 1 && v.z < a.depth / 2) &&
                    tri.Min(v => v.x) <= 0 && tri.Max(v => v.x) >= 0 && tri.Min(v => v.y) < 1.5 && tri.Max(v => v.y) > 1.5) obstruction = true;
            }
            Assert(!obstruction, a.id + " has a blocked central front doorway.");
        }
    }
    private static void Materials()
    {
        var s = new PbrSurface { id = "test", color = "#aa8855", pattern = "tile" };
        Assert(ArtPalette.Albedo(s, 32).SequenceEqual(ArtPalette.Albedo(s, 32)), "Material generation changed between runs.");
        Assert(Math.Abs(ArtPalette.Height("tile", 0.23, 0.4) - ArtPalette.Height("tile", 1.23, 1.4)) < 1e-8, "Tile material does not wrap.");
    }
    private static void MacroTint()
    {
        var (world, _) = Fixture();
        var sampler = new TerrainSampler(world);
        double variation = sampler.SurfaceVariation(-37.5, 91.25);
        Assert(variation >= 0.91 && variation <= 1.06, "Macro tint escaped its bounded color range.");
        Assert(variation == sampler.SurfaceVariation(-37.5, 91.25), "Macro tint is not repeatable.");
        Assert(Math.Abs(sampler.SurfaceVariation(-1e-5, 13) - sampler.SurfaceVariation(1e-5, 13)) < 0.001,
            "Macro tint has a discontinuity across a cell boundary.");
        world.seed++;
        Assert(Math.Abs(variation - new TerrainSampler(world).SurfaceVariation(-37.5, 91.25)) > 1e-6,
            "Macro tint does not respond to the world seed.");
        int n = (int)Math.Round(world.grid.cellSize / world.terrain.gridSpacing), side = n + 1;
        var left = WorldGeometry.Terrain(world, new CellKey(0, 0)).vertices;
        var right = WorldGeometry.Terrain(world, new CellKey(1, 0)).vertices;
        for (int z = 0; z <= n; z++)
        {
            var a = left[z * side + n]; var b = right[z * side];
            Assert(a.r == b.r && a.g == b.g && a.b == b.b, "Macro terrain color split at a cell seam.");
        }
    }

    private static void GroundWinding()
    {
        var (w, _) = Fixture();
        foreach (var mesh in new[] { WorldGeometry.Terrain(w, new CellKey(0, 0)), WorldGeometry.Water(new LakeSpec()) })
            for (int i = 0; i < mesh.triangles.Length; i += 3)
            {
                var a = mesh.vertices[mesh.triangles[i]]; var b = mesh.vertices[mesh.triangles[i + 1]]; var c = mesh.vertices[mesh.triangles[i + 2]];
                Assert((b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z) > 0, "Ground faces downward.");
            }
    }
    private static void ArtCosts()
    { foreach (var a in Catalog()) Assert(a.triangles == ProceduralArt.Create(a, 0).TriangleCount, "Stale geometry cost for " + a.id); }
    private static void ArtDimensions()
    { var (w, a) = Fixture(); a.assets[0].width = 2; Has(w, a, "DESIGN_SPEC"); }
    private static void TextureBudget()
    {
        var w = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath); var a = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
        long before = WorldCompiler.Compile(w, a).cells.Max(c => c.cost.textureKiB);
        w.visuals.textureResolution *= 2;
        long after = WorldCompiler.Compile(w, a).cells.Max(c => c.cost.textureKiB);
        Assert(after >= before * 3.99 && after <= before * 4.01, "Resolution upgrade bypassed the texture budget.");
    }

    private static ArtMesh CrossRoad()
    {
        var (w, _) = Fixture();
        w.roads = new[] {
            new RoadSpec { id = "A", width = 8, points = new[] { new Point2(-100,0), new Point2(100,0) } },
            new RoadSpec { id = "B", width = 8, points = new[] { new Point2(0,-100), new Point2(0,100) } }
        };
        return RoadSurface.Network(w);
    }
    private static void RoadUnionArea()
    {
        var mesh = CrossRoad(); double area = 0;
        for (int i = 0; i < mesh.triangles.Length; i += 3)
            area += RoadSurface.Area(Enumerable.Range(0, 3).Select(j => { var v = mesh.vertices[mesh.triangles[i + j]]; return new Point2(v.x, v.z); }).ToArray());
        Assert(Math.Abs(area - (2 * 200 * 8 - 8 * 8)) < 0.01, "Road union contains holes or duplicate overlap area: " + area);
    }
    private static void RoadUnionCoverage()
    {
        var mesh = CrossRoad();
        for (double z = -7.39; z < 8; z += 1) for (double x = -7.63; x < 8; x += 1)
        {
            int count = 0;
            for (int i = 0; i < mesh.triangles.Length; i += 3)
            {
                var triangle = Enumerable.Range(0, 3).Select(j => { var v = mesh.vertices[mesh.triangles[i + j]]; return new Point2(v.x, v.z); }).ToArray();
                if (Geometry.Contains(triangle, new Point2(x, z))) count++;
            }
            bool road = Math.Abs(x) < 4 || Math.Abs(z) < 4;
            Assert(count == (road ? 1 : 0), "Junction sample has " + count + " overlapping surfaces.");
        }
    }
}
