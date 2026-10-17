using Aaris.World;

namespace Aaris.Tools;

// A one-time, reviewed v1 -> v2 migration. Never called by CI or by ordinary edits.
public static class HighlandsRecipe
{
    public static (WorldSpec world, AssetRegistry assets) Create(WorldSpec original)
    {
        if (original.id != "Aaris_Highlands" || original.revision != 1 || original.schemaVersion != 1)
            throw new InvalidOperationException("This recipe only migrates the original Highlands r1. Preserve subsequent hand edits; do not regenerate them.");
        var assets = Catalog();
        var w = new WorldSpec
        {
            schemaVersion = 2, id = original.id, revision = 2, seed = original.seed,
            grid = new GridSpec(),
            terrain = new TerrainSpec { baseHeight = 4, amplitude = 7, noiseScale = 180, octaves = 3, gridSpacing = 4,
                hills = new[] { new HillSpec { x = -260, z = 270, radius = 260, height = 28 }, new HillSpec { x = 360, z = 40, radius = 180, height = 14 },
                    new HillSpec { x = -110, z = -370, radius = 190, height = 8 } },
                lakes = new[] { new LakeSpec { id = "LAKE_MIRROR", x = 15, z = 30, radiusX = 100, radiusZ = 70, surfaceY = 4, depth = 5, blend = 0.6 } } },
            design = new DesignSpec { enabled = true, maxTotalBuildings = 72, maxBuildingsPerCell = 9, maxTreesPerCell = 30,
                maxCellFootprintRatio = 0.28, maxWorldBuildingRatio = 0.04, minLandmarkSeparation = 170 },
            visuals = new VisualSpec { sunYaw = -38, sunPitch = 38, sunIntensity = 1.6, shadowDistance = 110, fogDensity = 0.0007, textureResolution = 256 },
            budget = new BudgetSpec { triangles = 120000, materialSlots = 220, textureKiB = 65536, colliders = 160, shadowCasters = 180, objects = 128 },
            streaming = new StreamingSpec { loadRadius = 160, unloadRadius = 208, maxResidentCells = 32 }
        };
        var definitions = new[] {
            (id: "POI_COURTS", name: "Saffron Courts", x: -275d, z: -250d, height: 10d, count: 14, asset: "courtyard_house"),
            (id: "POI_FOUNDRY", name: "Copper Foundry", x: 275d, z: -245d, height: 8d, count: 9, asset: "foundry_hall"),
            (id: "POI_STATION", name: "Ridge Station", x: -285d, z: 265d, height: 32d, count: 8, asset: "station_house"),
            (id: "POI_DEPOT", name: "Orchard Depot", x: 270d, z: 245d, height: 13d, count: 10, asset: "depot_store"),
            (id: "POI_WILLOW", name: "Willow Hamlet", x: -335d, z: 0d, height: 16d, count: 8, asset: "hamlet_cottage"),
            (id: "POI_QUARRY", name: "Basalt Quarry", x: 350d, z: 10d, height: 18d, count: 6, asset: "quarry_office")
        };
        w.landmarks = definitions.Select(p => new LandmarkSpec { id = p.id, name = p.name, x = p.x, z = p.z, radius = 112,
            minBuildings = p.count - 1, maxBuildings = p.count + 2, minApproaches = 2 }).ToArray();
        w.terrain.pads = definitions.Select(p => new TerrainPad { x = p.x, z = p.z, height = p.height, radius = 108, blend = 60 }).ToArray();
        w.biomes = new[] {
            new BiomeSpec { id = "BIO_NORTH_WOOD", kind = "woodland", x = -90, z = 320, radiusX = 170, radiusZ = 105, color = "#62794b", minTrees = 30, maxTrees = 65 },
            new BiomeSpec { id = "BIO_SOUTH_GROVE", kind = "woodland", x = -320, z = -385, radiusX = 160, radiusZ = 75, color = "#74834c", minTrees = 18, maxTrees = 45 },
            new BiomeSpec { id = "BIO_ORCHARD", kind = "orchard", x = 300, z = 360, radiusX = 150, radiusZ = 85, color = "#8c995d", minTrees = 16, maxTrees = 50 },
            new BiomeSpec { id = "BIO_LAKE_MEADOW", kind = "meadow", x = 0, z = 10, radiusX = 210, radiusZ = 180, color = "#8e9e61", minTrees = 0, maxTrees = 12 },
            new BiomeSpec { id = "BIO_QUARRY_SCRUB", kind = "scrub", x = 380, z = -70, radiusX = 120, radiusZ = 150, color = "#9e946e", minTrees = 0, maxTrees = 12 }
        };
        var C = new Point2(-275, -250); var F = new Point2(275, -245); var Q = new Point2(350, 10);
        var D = new Point2(270, 245); var R = new Point2(-285, 265); var W = new Point2(-335, 0);
        var routes = new[] {
            Route("PATH_CF", "POI_COURTS", "POI_FOUNDRY", C, new(-110,-285), new(100,-300), F),
            Route("PATH_FQ", "POI_FOUNDRY", "POI_QUARRY", F, new(350,-140), Q),
            Route("PATH_QD", "POI_QUARRY", "POI_DEPOT", Q, new(335,145), D),
            Route("PATH_DR", "POI_DEPOT", "POI_STATION", D, new(90,320), new(-100,325), R),
            Route("PATH_RW", "POI_STATION", "POI_WILLOW", R, new(-355,145), W),
            Route("PATH_WC", "POI_WILLOW", "POI_COURTS", W, new(-365,-135), C),
            Route("PATH_WF", "POI_WILLOW", "POI_FOUNDRY", W, new(-185,-100), new(0,-155), new(155,-180), F),
            Route("PATH_CR", "POI_COURTS", "POI_STATION", C, new(-205,-110), new(-170,65), new(-220,170), R)
        };
        w.routes = routes;
        var ring = new List<Point2>();
        foreach (var route in routes.Take(6)) ring.AddRange(ring.Count == 0 ? route.points : route.points.Skip(1));
        w.roads = new[] {
            new RoadSpec { id = "ROAD_RING", width = 8, clearance = 3, points = ring.ToArray() },
            new RoadSpec { id = "ROAD_EAST_WEST", width = 7, clearance = 3, points = routes[6].points },
            new RoadSpec { id = "ROAD_NORTH_SOUTH", width = 6, clearance = 3, points = routes[7].points }
        };
        var placer = new Placer(w, assets);
        foreach (var p in definitions)
        {
            var candidates = new List<Point2> { new(-42,-40), new(38,-38), new(-42,40), new(40,42) };
            for (int z = -3; z <= 3; z++) for (int x = -3; x <= 3; x++)
                if (x != 0 || z != 0) candidates.Add(new Point2(x * 30 + ((z + 3) % 2) * 4, z * 29));
            int placed = 0;
            foreach (var local in candidates)
            {
                if (placed == p.count) break;
                double x = p.x + local.x, z = p.z + local.z;
                if (Math.Sqrt(local.x * local.x + local.z * local.z) > 98) continue;
                string asset = placed >= 4 && p.id == "POI_COURTS" && placed % 3 == 0 ? "terrace_house" : p.asset;
                string id = p.id.Replace("POI_", "BLD_") + "_" + (placed + 1).ToString("D3");
                if (placer.Try(id, asset, x, z, Math.Round(Math.Atan2(p.x - x, p.z - z) * 180 / Math.PI / 15) * 15, p.id)) placed++;
            }
            if (placed != p.count) throw new InvalidOperationException("Insufficient valid building sites at " + p.id + ": " + placed);
            if (p.id != "POI_WILLOW" && p.id != "POI_QUARRY")
            {
                string id = p.id.Replace("POI_", "TWR_") + "_001";
                bool tower = new[] { new Point2(-78, 0), new Point2(80, 0), new Point2(0, 82), new Point2(0, -82) }
                    .Any(local => placer.Try(id, "lookout_tower", p.x + local.x, p.z + local.z, 0, p.id));
                if (!tower) throw new InvalidOperationException("No tower site for " + id);
            }
        }
        int rock = 0;
        foreach (var route in routes)
        {
            double next = 18; Point2? previous = null; double distance = 0;
            foreach (var point in WorldDesign.SampleRoute(route, 8))
            {
                if (!previous.HasValue) { previous = point; continue; }
                double dx = point.x - previous.Value.x, dz = point.z - previous.Value.z, length = Math.Sqrt(dx * dx + dz * dz);
                distance += length;
                if (distance >= next && length > 0)
                {
                    foreach (double offset in new[] { 14d, -14d, 20d, -20d })
                        if (placer.Try("ROCK_" + (rock + 1).ToString("D3"), "ridge_boulder", point.x - dz / length * offset, point.z + dx / length * offset, rock * 47 % 360, ""))
                        { rock++; break; }
                    next += 37 + rock % 13;
                }
                previous = point;
            }
        }
        if (rock < 12) throw new InvalidOperationException("Cover recipe did not preserve existing rock IDs.");
        var rng = new StableRandom((uint)w.seed);
        int trees = 0;
        // Poisson-style rejection with local density caps and reserved routes; no unbounded scatter.
        for (int attempt = 0; trees < 210 && attempt < 30000; attempt++)
        {
            double x, z;
            if (trees < 115)
            {
                var biome = w.biomes[trees % 3]; double angle = rng.Unit() * 2 * Math.PI, radius = Math.Sqrt(rng.Unit()) * 0.95;
                x = biome.x + Math.Cos(angle) * biome.radiusX * radius; z = biome.z + Math.Sin(angle) * biome.radiusZ * radius;
            }
            else { x = -470 + rng.Unit() * 940; z = -470 + rng.Unit() * 940; }
            if (w.biomes.Where(b => b.kind == "meadow" || b.kind == "scrub").Any(b => Math.Pow((x - b.x) / b.radiusX, 2) + Math.Pow((z - b.z) / b.radiusZ, 2) < 1) && trees % 7 != 0) continue;
            if (placer.Try("TREE_" + (trees + 1).ToString("D3"), trees % 3 == 0 ? "ridge_pine" : "canopy_tree", x, z, rng.Unit() * 360, "")) trees++;
        }
        if (trees != 210) throw new InvalidOperationException("Vegetation cap/spacing constraints prevented completion.");
        foreach (var p in definitions)
            for (int i = 0; i < 6; i++)
            {
                double angle = i * 2.4, radius = 18 + i * 5;
                placer.Try("COVER_" + p.id.Substring(4) + "_" + i, i % 2 == 0 ? "concrete_cover" : "supply_crate", p.x + Math.Sin(angle) * radius, p.z + Math.Cos(angle) * radius, i * 37, p.id);
            }
        w.objects = placer.Objects.ToArray();
        var courts = w.objects.Single(o => o.id == "BLD_COURTS_001");
        w.markers = new[] { new MarkerSpec { id = "M001", x = courts.x + 0.25, z = courts.z + 0.25, yaw = courts.yaw }, new MarkerSpec { id = "M002", x = 112, z = 150, yaw = 180 } };
        var oldIds = original.objects.Select(o => o.id).ToHashSet(StringComparer.Ordinal);
        if (!oldIds.IsSubsetOf(w.objects.Select(o => o.id))) throw new InvalidOperationException("Recipe would lose permanent v1 object IDs.");
        var errors = WorldValidator.Validate(w, assets);
        if (errors.Count > 0) throw new InvalidOperationException("V2 proposal rejected:\n" + string.Join("\n", errors));
        return (w, assets);
    }

    private static RouteSpec Route(string id, string from, string to, params Point2[] control)
    {
        var points = new List<Point2>();
        // Catmull-Rom sampled into source data, so validation and rendering use identical curves.
        for (int i = 0; i < control.Length - 1; i++)
        {
            var a = control[Math.Max(0, i - 1)]; var b = control[i]; var c = control[i + 1]; var d = control[Math.Min(control.Length - 1, i + 2)];
            int steps = Math.Max(2, (int)Math.Ceiling(WorldDesign.Distance(b, c) / 12));
            for (int j = 0; j < steps; j++)
            {
                double t = (double)j / steps;
                double Blend(double p, double q, double r, double s) => 0.5 * (2 * q + (-p + r) * t + (2 * p - 5 * q + 4 * r - s) * t * t + (-p + 3 * q - 3 * r + s) * t * t * t);
                points.Add(new Point2(Blend(a.x, b.x, c.x, d.x), Blend(a.z, b.z, c.z, d.z)));
            }
        }
        points.Add(control[^1]);
        return new RouteSpec { id = id, from = from, to = to, points = points.ToArray(), width = 4, maxCoverGap = 65, coverSearchRadius = 28, maxSlopeDegrees = 25 };
    }

    private static AssetRegistry Catalog()
    {
        var rows = new[] {
            ("courtyard_house", "building", "house", 14d,12d,7d,"#c8b28a","#9b5036"),
            ("foundry_hall", "building", "warehouse",24d,18d,10d,"#a8aaa0","#65737b"),
            ("station_house", "building", "station",16d,12d,8d,"#c3c7ba","#455865"),
            ("depot_store", "building", "barn",20d,16d,8d,"#b8a379","#844834"),
            ("lookout_tower", "tower", "tower",7d,7d,16d,"#a28d6c","#596b70"),
            ("ridge_boulder", "rock", "boulder",6d,5d,3.2d,"#90948b","#555555"),
            ("canopy_tree", "tree", "oak",8d,8d,12d,"#527542","#555555"),
            ("ridge_pine", "tree", "pine",6d,6d,15d,"#3e6249","#555555"),
            ("terrace_house", "building", "townhouse",13d,13d,9d,"#d7cba9","#7d5347"),
            ("hamlet_cottage", "building", "house",11d,10d,6.2d,"#c4b886","#7d4e34"),
            ("quarry_office", "building", "warehouse",14d,12d,6d,"#afada0","#697577"),
            ("concrete_cover", "cover", "barrier",4d,1.3d,1.2d,"#a2a494","#555555"),
            ("supply_crate", "cover", "crate",1.8d,1.5d,1.3d,"#87734f","#555555")
        };
        var registry = new AssetRegistry { schemaVersion = 2, assets = rows.Select((r, i) => new AssetSpec { id = r.Item1, previewShape = r.Item2, archetype = r.Item3,
            width = r.Item4, depth = r.Item5, height = r.Item6, color = r.Item7, roofColor = r.Item8, artSeed = 1701 + i * 137,
            clearance = r.Item2 == "tree" ? 4 : 2, maxSlopeDegrees = r.Item2 == "building" ? 12 : 38, maxRelief = r.Item2 == "building" ? 1.5 : 4,
            source = "Original Aaris parameterized development art v2", license = "Project-owned", providesCover = r.Item2 == "building" || r.Item2 == "rock" || r.Item2 == "cover" }).ToArray() };
        foreach (var asset in registry.assets)
        {
            var model = ProceduralArt.Create(asset, 0);
            asset.triangles = model.TriangleCount; asset.materialSlots = model.parts.Length;
            asset.colliders = model.collision.vertices.Length > 0 ? 1 : 0; asset.shadowCasters = model.parts.Count(p => p.material != "glass");
            // RGBA albedo+normal, with mipmaps, conservatively counted per asset material.
            asset.textureKiB = model.parts.Length * 256L * 256 * 8 * 4 / 3 / 1024;
        }
        return registry;
    }

    private sealed class Placer
    {
        public readonly List<ObjectSpec> Objects = new();
        private readonly WorldSpec w; private readonly Dictionary<string, AssetSpec> assets; private readonly TerrainSampler terrain;
        public Placer(WorldSpec w, AssetRegistry registry) { this.w = w; assets = registry.assets.ToDictionary(a => a.id); terrain = new TerrainSampler(w); }
        public bool Try(string id, string assetId, double x, double z, double yaw, string landmark)
        {
            var a = assets[assetId];
            var o = new ObjectSpec { id = id, asset = assetId, landmark = landmark, x = Math.Round(x, 3), z = Math.Round(z, 3), yaw = Math.Round(yaw, 2) };
            var footprint = Geometry.Footprint(o, a); var padded = Geometry.Footprint(o, a, a.clearance / 2);
            if (a.previewShape == "building")
            {
                var district = w.landmarks.Single(p => p.id == landmark);
                if (footprint.Any(p => WorldDesign.Distance(p, new Point2(district.x, district.z)) > district.radius)) return false;
            }
            if (footprint.Any(p => !WorldValidator.Inside(w.grid, p.x, p.z)) || w.terrain.lakes.Any(l => WorldDesign.IntersectsLake(footprint, l))) return false;
            foreach (var road in w.roads) for (int i = 1; i < road.points.Length; i++)
                if (Geometry.PolygonSegmentDistance(footprint, road.points[i - 1], road.points[i]) < road.width / 2 + road.clearance) return false;
            foreach (var route in w.routes) for (int i = 1; i < route.points.Length; i++)
                if (Geometry.PolygonSegmentDistance(footprint, route.points[i - 1], route.points[i]) < route.width / 2 + 0.5) return false;
            if (Objects.Any(other => Geometry.Overlaps(padded, Geometry.Footprint(other, assets[other.asset], assets[other.asset].clearance / 2)))) return false;
            if (a.previewShape == "tree" && Objects.Count(other => assets[other.asset].previewShape == "tree" && WorldCompiler.CellAt(w.grid, other.x, other.z).Equals(WorldCompiler.CellAt(w.grid, x, z))) >= w.design.maxTreesPerCell - 2) return false;
            if (a.previewShape == "building" && Objects.Count(other => assets[other.asset].previewShape == "building" && WorldCompiler.CellAt(w.grid, other.x, other.z).Equals(WorldCompiler.CellAt(w.grid, x, z))) >= w.design.maxBuildingsPerCell) return false;
            double low = double.MaxValue, high = double.MinValue;
            int nx = Math.Max(2, (int)Math.Ceiling(a.width / w.terrain.gridSpacing)), nz = Math.Max(2, (int)Math.Ceiling(a.depth / w.terrain.gridSpacing));
            for (int iz = 0; iz <= nz; iz++) for (int ix = 0; ix <= nx; ix++)
            {
                double u = (double)ix / nx, v = (double)iz / nz;
                double px = footprint[0].x + u * (footprint[1].x - footprint[0].x) + v * (footprint[3].x - footprint[0].x);
                double pz = footprint[0].z + u * (footprint[1].z - footprint[0].z) + v * (footprint[3].z - footprint[0].z);
                double height = terrain.Height(px, pz); low = Math.Min(low, height); high = Math.Max(high, height);
                if (terrain.SlopeDegrees(px, pz) > a.maxSlopeDegrees) return false;
            }
            if (high - low > a.maxRelief) return false;
            Objects.Add(o); return true;
        }
    }

    private sealed class StableRandom
    {
        private uint state;
        public StableRandom(uint seed) { state = seed == 0 ? 1 : seed; }
        public double Unit() { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state / 4294967296.0; }
    }
}
