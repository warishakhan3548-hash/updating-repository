using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace Aaris.World
{
    [Serializable]
    public sealed class DesignReport
    {
        public int buildings;
        public int trees;
        public int coverObjects;
        public double buildingFootprintRatio;
        public int peakCellBuildings;
        public int peakCellTrees;
        public double peakCellFootprintRatio;
        public DistrictReport[] districts;
        public RouteReport[] routes;
    }

    [Serializable]
    public sealed class DistrictReport
    {
        public string id;
        public int buildings;
        public int approaches;
    }

    [Serializable]
    public sealed class RouteReport
    {
        public string id;
        public double length;
        public double longestUncoveredMetres;
        public double steepestSlopeDegrees;
    }

    public static class WorldDesign
    {
        private static readonly string[] Archetypes = { "", "house", "townhouse", "warehouse", "barn", "station", "tower", "oak", "pine", "boulder", "barrier", "crate" };
        private static bool Color(string text) { return text != null && Regex.IsMatch(text, "^#[0-9A-Fa-f]{6}$"); }
        private static bool Id(string text) { return text != null && Regex.IsMatch(text, "^[A-Za-z][A-Za-z0-9_-]{0,63}$"); }

        public static List<Diagnostic> ValidateDefinitions(WorldSpec w, AssetRegistry registry)
        {
            var errors = new List<Diagnostic>();
            void Error(string id, string message) { errors.Add(new Diagnostic("DESIGN_SPEC", id, message)); }
            if (w.biomes == null || w.routes == null || w.design == null || w.visuals == null || w.terrain.hills == null || w.terrain.lakes == null)
            { Error(w.id, "V2 sections cannot be null."); return errors; }
            if (w.biomes.Length > 128 || w.routes.Length > 256 || w.terrain.hills.Length > 128 || w.terrain.lakes.Length > 32)
            { Error(w.id, "V2 sections exceed authoring limits."); return errors; }
            if (w.schemaVersion < 2 && (w.biomes.Length + w.routes.Length + w.terrain.hills.Length + w.terrain.lakes.Length > 0 || w.design.enabled))
                errors.Add(new Diagnostic("SCHEMA_VERSION", w.id, "V2 terrain/design features require schemaVersion 2."));
            var d = w.design; var v = w.visuals;
            if (!WorldValidator.Finite(d.maxCellFootprintRatio, d.maxWorldBuildingRatio, d.minLandmarkSeparation) ||
                d.maxTotalBuildings < 1 || d.maxTotalBuildings > 5000 || d.maxBuildingsPerCell < 1 || d.maxBuildingsPerCell > 256 ||
                d.maxTreesPerCell < 1 || d.maxTreesPerCell > 512 || d.maxCellFootprintRatio <= 0 || d.maxCellFootprintRatio > 0.75 ||
                d.maxWorldBuildingRatio <= 0 || d.maxWorldBuildingRatio > 0.5 || d.minLandmarkSeparation < 0 || d.minLandmarkSeparation > 8192)
                Error(w.id, "Invalid building/tree density or landmark spacing limits.");
            if (!WorldValidator.Finite(v.sunYaw, v.sunPitch, v.sunIntensity, v.shadowDistance, v.fogDensity, v.windAngleDegrees, v.windFrequencyHz, v.windActiveDistance) ||
                Math.Abs(v.sunYaw) > 360 || v.sunPitch < 5 || v.sunPitch > 85 || v.sunIntensity < 0.1 || v.sunIntensity > 5 ||
                v.shadowDistance < 10 || v.shadowDistance > 300 || v.fogDensity < 0 || v.fogDensity > 0.01 || !Color(v.fogColor) ||
                v.textureResolution < 32 || v.textureResolution > 512 || (v.textureResolution & (v.textureResolution - 1)) != 0 ||
                v.windAngleDegrees < 0 || v.windAngleDegrees > 8 || v.windFrequencyHz <= 0 || v.windFrequencyHz > 2 ||
                v.windActiveDistance < 20 || v.windActiveDistance > 1000)
                Error(w.id, "Invalid bounded visual profile or texture resolution.");
            var used = new HashSet<string>(w.objects.Where(o => o != null).Select(o => o.id)
                .Concat(w.landmarks.Where(p => p != null).Select(p => p.id))
                .Concat(w.markers.Where(m => m != null).Select(m => m.id))
                .Concat(w.roads.Where(r => r != null).Select(r => r.id)), StringComparer.Ordinal);
            void Unique(string id) { if (!Id(id) || !used.Add(id)) Error(id, "Invalid or duplicate v2 ID."); }
            foreach (var h in w.terrain.hills)
                if (h == null || !WorldValidator.Finite(h.x, h.z, h.radius, h.height) || !WorldValidator.Inside(w.grid, h.x, h.z) ||
                    h.radius < 10 || h.radius > 2000 || Math.Abs(h.height) > 500) Error(w.id, "Invalid hill dimensions.");
            foreach (var lake in w.terrain.lakes)
            {
                if (lake == null) { Error(w.id, "Null lake."); continue; }
                Unique(lake.id);
                if (!WorldValidator.Finite(lake.x, lake.z, lake.radiusX, lake.radiusZ, lake.surfaceY, lake.depth, lake.blend) ||
                    lake.radiusX < 8 || lake.radiusZ < 8 || lake.radiusX > 1000 || lake.radiusZ > 1000 || lake.depth < 1 || lake.depth > 100 ||
                    Math.Abs(lake.surfaceY) > 10000 || lake.blend <= 0 || lake.blend > 2 ||
                    !WorldValidator.Inside(w.grid, lake.x - lake.radiusX, lake.z - lake.radiusZ) || !WorldValidator.Inside(w.grid, lake.x + lake.radiusX, lake.z + lake.radiusZ))
                    Error(lake.id, "Invalid lake footprint/depth.");
            }
            foreach (var biome in w.biomes)
            {
                if (biome == null) { Error(w.id, "Null biome."); continue; }
                Unique(biome.id);
                if (!WorldValidator.Finite(biome.x, biome.z, biome.radiusX, biome.radiusZ) || biome.radiusX < 10 || biome.radiusZ < 10 ||
                    biome.radiusX > 2000 || biome.radiusZ > 2000 || !WorldValidator.Inside(w.grid, biome.x, biome.z) || !Color(biome.color) ||
                    biome.minTrees < 0 || biome.maxTrees < biome.minTrees || biome.maxTrees > 5000 ||
                    !new[] { "woodland", "meadow", "scrub", "orchard" }.Contains(biome.kind)) Error(biome.id, "Invalid biome/density definition.");
            }
            var landmarks = w.landmarks.Where(p => p != null && p.id != null).GroupBy(p => p.id).ToDictionary(g => g.Key, g => g.First());
            foreach (var landmark in landmarks.Values)
                if (landmark.minBuildings < 0 || landmark.maxBuildings < landmark.minBuildings || landmark.maxBuildings > 1000 ||
                    landmark.minApproaches < 0 || landmark.minApproaches > 16) Error(landmark.id, "Invalid district population/approach limits.");
            foreach (var route in w.routes)
            {
                if (route == null) { Error(w.id, "Null route."); continue; }
                Unique(route.id);
                if (route.from == null || route.to == null || route.from == route.to || !landmarks.ContainsKey(route.from) || !landmarks.ContainsKey(route.to) ||
                    route.points == null || route.points.Length < 2 || route.points.Length > 2048 ||
                    !WorldValidator.Finite(route.width, route.maxCoverGap, route.coverSearchRadius, route.maxSlopeDegrees) ||
                    route.width < 1 || route.width > 12 || route.maxCoverGap < 8 || route.maxCoverGap > 250 ||
                    route.coverSearchRadius < 5 || route.coverSearchRadius > 80 || route.maxSlopeDegrees < 1 || route.maxSlopeDegrees > 45)
                { Error(route.id, "Invalid route endpoints, dimensions or cover/slope limits."); continue; }
                for (int i = 0; i < route.points.Length; i++)
                {
                    var p = route.points[i];
                    if (!WorldValidator.Finite(p.x, p.z) || !WorldValidator.Inside(w.grid, p.x, p.z)) Error(route.id, "Out-of-bounds/non-finite route point.");
                    if (i > 0 && Distance(p, route.points[i - 1]) < 0.01) Error(route.id, "Duplicate consecutive route point.");
                }
                var from = landmarks[route.from]; var to = landmarks[route.to];
                if (Distance(route.points[0], new Point2(from.x, from.z)) > 1 || Distance(route.points[route.points.Length - 1], new Point2(to.x, to.z)) > 1)
                    Error(route.id, "Route endpoints must reach their district centres within one metre.");
            }
            foreach (var a in registry.assets.Where(a => a != null))
            {
                if (!Archetypes.Contains(a.archetype) || !Color(a.roofColor)) Error(a.id, "Unknown procedural archetype or invalid roof color.");
                if (new[] { "house", "warehouse", "barn", "townhouse", "station" }.Contains(a.archetype) &&
                    (a.width < 6 || a.depth < 6 || a.height < (a.archetype == "townhouse" || a.archetype == "station" ? 7.5 : 4.8)))
                    Error(a.id, "Procedural architecture dimensions are too small for the authored openings/floors.");
                if (a.archetype == "tower" && (a.width < 3 || a.depth < 3 || a.height < 6)) Error(a.id, "Tower dimensions are too small.");
                if ((a.archetype == "oak" || a.archetype == "pine") && (a.width < 1 || a.depth < 1 || a.height < 3)) Error(a.id, "Tree dimensions are too small.");
            }
            return errors;
        }

        public static double Distance(Point2 a, Point2 b) { double x = a.x - b.x, z = a.z - b.z; return Math.Sqrt(x * x + z * z); }
        public static bool IntersectsLake(Point2[] polygon, LakeSpec lake)
        {
            var normalized = polygon.Select(p => new Point2((p.x - lake.x) / lake.radiusX, (p.z - lake.z) / lake.radiusZ)).ToArray();
            if (Geometry.Contains(normalized, new Point2(0, 0))) return true;
            for (int i = 0; i < normalized.Length; i++)
                if (Geometry.PointSegmentDistance(new Point2(0, 0), normalized[i], normalized[(i + 1) % normalized.Length]) <= 1.05) return true;
            return false;
        }

        public static IEnumerable<Point2> SampleRoute(RouteSpec route, double spacing = 8)
        {
            yield return route.points[0];
            for (int i = 1; i < route.points.Length; i++)
            {
                var a = route.points[i - 1]; var b = route.points[i];
                int n = Math.Max(1, (int)Math.Ceiling(Distance(a, b) / spacing));
                for (int j = 1; j <= n; j++) yield return new Point2(a.x + (b.x - a.x) * j / n, a.z + (b.z - a.z) * j / n);
            }
        }

        public static DesignReport Analyze(WorldSpec w, AssetRegistry registry)
        {
            var assets = registry.assets.ToDictionary(a => a.id);
            var buildings = w.objects.Where(o => assets[o.asset].previewShape == "building").ToArray();
            var terrain = new TerrainSampler(w);
            var cover = w.objects.Where(o => assets[o.asset].providesCover).Select(o => Geometry.Footprint(o, assets[o.asset])).ToArray();
            var report = new DesignReport { buildings = buildings.Length, trees = w.objects.Count(o => assets[o.asset].previewShape == "tree"), coverObjects = cover.Length,
                buildingFootprintRatio = buildings.Sum(o => assets[o.asset].width * assets[o.asset].depth * o.scale * o.scale) / (w.grid.sizeX * w.grid.sizeZ),
                districts = w.landmarks.Select(p => new DistrictReport { id = p.id, buildings = buildings.Count(o => o.landmark == p.id),
                    approaches = w.routes.Where(r => r.from == p.id || r.to == p.id).Select(r => r.from == p.id ? r.to : r.from).Distinct().Count() }).ToArray() };
            foreach (var group in w.objects.GroupBy(o => WorldCompiler.CellAt(w.grid, o.x, o.z)))
            {
                report.peakCellBuildings = Math.Max(report.peakCellBuildings, group.Count(o => assets[o.asset].previewShape == "building"));
                report.peakCellTrees = Math.Max(report.peakCellTrees, group.Count(o => assets[o.asset].previewShape == "tree"));
            }
            // Sum full footprints of referenced objects: conservative bound, not exact polygon occupancy.
            var occupancy = new Dictionary<CellKey, double>();
            foreach (var o in w.objects)
                foreach (var cell in Geometry.TouchedCells(w.grid, Geometry.Footprint(o, assets[o.asset])))
                {
                    if (!occupancy.ContainsKey(cell)) occupancy[cell] = 0;
                    occupancy[cell] += assets[o.asset].width * assets[o.asset].depth * o.scale * o.scale / (w.grid.cellSize * w.grid.cellSize);
                }
            report.peakCellFootprintRatio = occupancy.Count == 0 ? 0 : occupancy.Values.Max();
            var routes = new List<RouteReport>();
            foreach (var route in w.routes)
            {
                var rr = new RouteReport { id = route.id }; double gap = 0; Point2? previous = null;
                foreach (var p in SampleRoute(route, Math.Min(8, w.terrain.gridSpacing)))
                {
                    double step = previous.HasValue ? Distance(previous.Value, p) : 0;
                    rr.length += step;
                    rr.steepestSlopeDegrees = Math.Max(rr.steepestSlopeDegrees, terrain.SlopeDegrees(p.x, p.z));
                    bool covered = cover.Any(poly => Geometry.Contains(poly, p) || Enumerable.Range(0, poly.Length)
                        .Any(i => Geometry.PointSegmentDistance(p, poly[i], poly[(i + 1) % poly.Length]) <= route.coverSearchRadius));
                    gap = covered ? 0 : gap + step;
                    rr.longestUncoveredMetres = Math.Max(rr.longestUncoveredMetres, gap); previous = p;
                }
                routes.Add(rr);
            }
            report.routes = routes.ToArray(); return report;
        }

        public static List<Diagnostic> CheckLayout(WorldSpec w, AssetRegistry registry)
        {
            var errors = new List<Diagnostic>();
            if (!w.design.enabled) return errors;
            void Error(string code, string id, string message) { errors.Add(new Diagnostic(code, id, message)); }
            var report = Analyze(w, registry); var d = w.design; var assets = registry.assets.ToDictionary(a => a.id);
            if (report.buildings > d.maxTotalBuildings || report.buildingFootprintRatio > d.maxWorldBuildingRatio)
                Error("WORLD_DENSITY", w.id, "Building count/footprint exceeds the world cap.");
            if (report.peakCellBuildings > d.maxBuildingsPerCell || report.peakCellTrees > d.maxTreesPerCell || report.peakCellFootprintRatio > d.maxCellFootprintRatio)
                Error("CELL_DENSITY", w.id, "Peak buildings=" + report.peakCellBuildings + "/" + d.maxBuildingsPerCell + ", trees=" + report.peakCellTrees + "/" + d.maxTreesPerCell +
                    ", conservative footprint=" + report.peakCellFootprintRatio.ToString("0.000") + "/" + d.maxCellFootprintRatio + ".");
            foreach (var district in report.districts)
            {
                var spec = w.landmarks.Single(p => p.id == district.id);
                if (district.buildings < spec.minBuildings || district.buildings > spec.maxBuildings) Error("DISTRICT_DENSITY", district.id, "District building population is outside its intended range.");
                if (district.approaches < spec.minApproaches) Error("DISTRICT_APPROACHES", district.id, "District needs more distinct route neighbours.");
            }
            foreach (var o in w.objects.Where(o => assets[o.asset].previewShape == "building"))
            {
                var district = w.landmarks.SingleOrDefault(p => p.id == o.landmark);
                if (district == null || Geometry.Footprint(o, assets[o.asset]).Any(p => Distance(p, new Point2(district.x, district.z)) > district.radius))
                    Error("DISTRICT_BOUNDS", o.id, "Buildings must remain inside their assigned district, leaving intentional countryside between settlements.");
            }
            for (int i = 0; i < w.landmarks.Length; i++)
                for (int j = i + 1; j < w.landmarks.Length; j++)
                    if (Distance(new Point2(w.landmarks[i].x, w.landmarks[i].z), new Point2(w.landmarks[j].x, w.landmarks[j].z)) < d.minLandmarkSeparation)
                        Error("LANDMARK_SPACING", w.landmarks[i].id, "District centres are too close.");
            foreach (var biome in w.biomes)
            {
                int trees = w.objects.Count(o => assets[o.asset].previewShape == "tree" && Math.Pow((o.x - biome.x) / biome.radiusX, 2) + Math.Pow((o.z - biome.z) / biome.radiusZ, 2) <= 1);
                if (trees < biome.minTrees || trees > biome.maxTrees) Error("BIOME_DENSITY", biome.id, "Tree population is outside the biome's intended range.");
            }
            foreach (var route in w.routes)
            {
                var stats = report.routes.Single(r => r.id == route.id);
                if (stats.longestUncoveredMetres > route.maxCoverGap + 0.01) Error("ROUTE_COVER", route.id, "Uncovered traversal exceeds " + route.maxCoverGap + " m.");
                if (stats.steepestSlopeDegrees > route.maxSlopeDegrees + 0.01) Error("ROUTE_SLOPE", route.id, "Peak " + stats.steepestSlopeDegrees.ToString("0.0") + " degrees exceeds " + route.maxSlopeDegrees + ".");
                foreach (var o in w.objects.Where(o => assets[o.asset].blocksPlacement))
                    for (int i = 1; i < route.points.Length; i++)
                        if (Geometry.PolygonSegmentDistance(Geometry.Footprint(o, assets[o.asset]), route.points[i - 1], route.points[i]) < route.width / 2)
                        { Error("ROUTE_BLOCKED", route.id, "Reserved walking corridor blocked by " + o.id + "."); break; }
                foreach (var p in SampleRoute(route, w.terrain.gridSpacing))
                    if (w.terrain.lakes.Any(lake => Math.Pow((p.x - lake.x) / lake.radiusX, 2) + Math.Pow((p.z - lake.z) / lake.radiusZ, 2) <= 1.05 * 1.05))
                    { Error("ROUTE_WATER", route.id, "Route crosses water without a designed crossing."); break; }
            }
            foreach (var road in w.roads)
                foreach (var p in SampleRoute(new RouteSpec { points = road.points }, w.terrain.gridSpacing))
                    if (w.terrain.lakes.Any(lake => Math.Pow((p.x - lake.x) / lake.radiusX, 2) + Math.Pow((p.z - lake.z) / lake.radiusZ, 2) <= 1.05 * 1.05))
                    { Error("ROAD_WATER", road.id, "Road crosses reserved water without a designed crossing."); break; }
            if (w.landmarks.Length > 1)
            {
                bool Connected(RouteSpec excluded)
                {
                    var reached = new HashSet<string> { w.landmarks[0].id }; bool changed;
                    do
                    {
                        changed = false;
                        foreach (var route in w.routes.Where(r => r != excluded))
                            if (reached.Contains(route.from) || reached.Contains(route.to))
                            { changed |= reached.Add(route.from); changed |= reached.Add(route.to); }
                    } while (changed);
                    return reached.Count == w.landmarks.Length;
                }
                if (!Connected(null)) Error("ROUTE_CONNECTIVITY", w.id, "District route graph is disconnected.");
                else if (d.requireRedundantRoutes && w.routes.Any(route => !Connected(route)))
                    Error("ROUTE_REDUNDANCY", w.id, "A single missing connection isolates a district.");
            }
            return errors;
        }
    }
}
