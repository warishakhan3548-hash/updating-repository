using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace Aaris.World
{
    [Serializable]
    public sealed class Diagnostic
    {
        public string code;
        public string subject;
        public string message;
        public Diagnostic(string code, string subject, string message)
        { this.code = code; this.subject = subject; this.message = message; }
        public override string ToString() { return code + " [" + subject + "]: " + message; }
    }

    public static class WorldValidator
    {
        private static readonly Regex IdPattern = new Regex("^[A-Za-z][A-Za-z0-9_-]{0,63}$");
        private static readonly Regex ColorPattern = new Regex("^#[0-9a-fA-F]{6}$");
        public static bool Finite(params double[] values)
        { return values.All(v => !double.IsNaN(v) && !double.IsInfinity(v)); }

        public static List<Diagnostic> Validate(WorldSpec world, AssetRegistry registry, bool production = false)
        {
            var errors = new List<Diagnostic>();
            void Error(string code, string id, string message) { errors.Add(new Diagnostic(code, id, message)); }
            bool Id(string id) { return id != null && IdPattern.IsMatch(id); }
            if (world == null || registry == null)
            { Error("MISSING_DOCUMENT", "world", "World and asset registry are required."); return errors; }
            if ((world.schemaVersion != 1 && world.schemaVersion != 2) || (registry.schemaVersion != 1 && registry.schemaVersion != 2))
                Error("SCHEMA_VERSION", "world", "Only schema versions 1 and 2 are supported.");
            if (!Id(world.id) || world.revision < 1) Error("WORLD_ID", "world", "Use a stable ID and a positive revision.");
            if (world.grid == null || world.terrain == null || world.budget == null || world.streaming == null ||
                world.objects == null || world.roads == null || world.landmarks == null || world.markers == null || registry.assets == null)
            { Error("MISSING_SECTION", world.id, "All world sections and arrays are required and cannot be null."); return errors; }
            var g = world.grid; var t = world.terrain; var b = world.budget; var s = world.streaming;
            if (!Finite(g.originX, g.originZ, g.sizeX, g.sizeZ, g.cellSize) || g.sizeX <= 0 || g.sizeZ <= 0 ||
                g.sizeX > 8192 || g.sizeZ > 8192 || g.cellSize < 16 || g.cellSize > 1024 ||
                Math.Abs(g.originX) > 100000 || Math.Abs(g.originZ) > 100000 ||
                !Multiple(g.sizeX, g.cellSize) || !Multiple(g.sizeZ, g.cellSize) || g.sizeX / g.cellSize * g.sizeZ / g.cellSize > 4096)
                Error("GRID", world.id, "Use finite bounds, integral cell counts, 16–1024 m cells, at most 4096 cells and 8192 m per axis.");
            if (!Finite(t.baseHeight, t.amplitude, t.noiseScale, t.gridSpacing) || Math.Abs(t.baseHeight) > 10000 ||
                t.amplitude < 0 || t.amplitude > 1000 || t.noiseScale < 1 || t.noiseScale > 100000 || t.octaves < 1 || t.octaves > 8 ||
                t.gridSpacing < 1 || !Multiple(g.cellSize, t.gridSpacing) || g.cellSize / t.gridSpacing > 128 || t.pads == null || t.pads.Length > 256)
                Error("TERRAIN", world.id, "Use 1–8 octaves and a mesh spacing that exactly divides each cell (at most 128 segments per edge).");
            if (b.triangles <= 0 || b.triangles > 100000000 || b.materialSlots <= 0 || b.materialSlots > 1000000 ||
                b.textureKiB <= 0 || b.textureKiB > 100000000 || b.colliders <= 0 || b.colliders > 1000000 ||
                b.shadowCasters <= 0 || b.shadowCasters > 1000000 || b.objects <= 0 || b.objects > 100000)
                Error("BUDGET", world.id, "Every per-cell budget must be positive and bounded.");
            if (!Finite(s.loadRadius, s.unloadRadius) || s.loadRadius <= 0 || s.unloadRadius <= s.loadRadius ||
                s.unloadRadius > 16384 || s.maxResidentCells < 1 || s.maxResidentCells > 4096)
                Error("STREAMING", world.id, "Use 0 < loadRadius < unloadRadius and 1–4096 resident cells.");
            if (world.objects.Length > 20000 || registry.assets.Length > 2048 || world.roads.Length > 1024 || world.markers.Length > 4096 || world.landmarks.Length > 1024)
                Error("AUTHORING_LIMIT", world.id, "Split this world before exceeding authoring limits.");
            if (errors.Count > 0) return errors;
            errors.AddRange(WorldDesign.ValidateDefinitions(world, registry));
            if (errors.Count > 0) return errors;

            foreach (var pad in t.pads)
                if (pad == null || !Finite(pad.x, pad.z, pad.height, pad.radius, pad.blend) || pad.radius <= 0 || pad.blend <= 0 ||
                    Math.Abs(pad.height) > 10000 || pad.radius > 8192 || pad.blend > 8192 || !Inside(g, pad.x, pad.z))
                    Error("TERRAIN_PAD", world.id, "Pads need finite, bounded dimensions and centres inside the world.");

            var assets = new Dictionary<string, AssetSpec>(StringComparer.Ordinal);
            foreach (var a in registry.assets)
            {
                if (a == null) { Error("NULL_ASSET", "registry", "Null asset entry."); continue; }
                if (!Id(a.id) || assets.ContainsKey(a.id)) { Error("ASSET_ID", a.id, "Invalid or duplicate asset ID."); continue; }
                assets.Add(a.id, a);
                if (!Finite(a.width, a.depth, a.height, a.clearance, a.maxSlopeDegrees, a.maxRelief) ||
                    a.width <= 0 || a.depth <= 0 || a.height <= 0 || a.width > 1024 || a.depth > 1024 || a.height > 1024 ||
                    a.clearance < 0 || a.clearance > 100 || a.maxSlopeDegrees < 0 || a.maxSlopeDegrees > 80 || a.maxRelief < 0 || a.maxRelief > 100)
                    Error("ASSET_BOUNDS", a.id, "Invalid footprint, height or placement limits.");
                if (a.triangles < 0 || a.triangles > 10000000 || a.materialSlots < 0 || a.materialSlots > 10000 ||
                    a.textureKiB < 0 || a.textureKiB > 10000000 || a.colliders < 0 || a.colliders > 10000 || a.shadowCasters < 0 || a.shadowCasters > 10000)
                    Error("ASSET_COST", a.id, "Asset costs must be nonnegative, bounded estimates.");
                if (a.prefabPath == null || (a.prefabPath.Length > 0 &&
                    (!a.prefabPath.StartsWith("Assets/Art/", StringComparison.Ordinal) || !a.prefabPath.EndsWith(".prefab", StringComparison.Ordinal) ||
                     a.prefabPath.Contains("..") || a.prefabPath.Contains("\\") || a.prefabPath.Contains(":"))))
                    Error("ASSET_PATH", a.id, "Prefab paths must stay below Assets/Art and end in .prefab.");
                if (a.previewShape != "building" && a.previewShape != "tower" && a.previewShape != "rock" && a.previewShape != "tree" && a.previewShape != "cover")
                    Error("PREVIEW_SHAPE", a.id, "Unsupported blockout shape.");
                if (a.color == null || !ColorPattern.IsMatch(a.color) || string.IsNullOrWhiteSpace(a.source) || string.IsNullOrWhiteSpace(a.license))
                    Error("ASSET_METADATA", a.id, "Color, provenance and license are required.");
                if (production && string.IsNullOrWhiteSpace(a.prefabPath))
                    Error("PRODUCTION_ART", a.id, "Architectural blockout cannot pass the production-art gate.");
            }

            var ids = new HashSet<string>(StringComparer.Ordinal);
            void Unique(string id)
            { if (!Id(id) || !ids.Add(id)) Error("DUPLICATE_ID", id, "IDs must be valid and unique across world objects, roads, landmarks and markers."); }
            var landmarkIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var p in world.landmarks)
            {
                if (p == null) { Error("LANDMARK", world.id, "Null landmark."); continue; }
                Unique(p.id); if (p.id != null) landmarkIds.Add(p.id);
                if (string.IsNullOrWhiteSpace(p.name) || !Finite(p.x, p.z, p.radius) || p.radius <= 0 || p.radius > 8192 || !Inside(g, p.x, p.z))
                    Error("LANDMARK", p.id, "A named landmark needs a finite, in-bounds centre and positive radius.");
            }
            foreach (var m in world.markers)
            {
                if (m == null) { Error("MARKER", world.id, "Null marker."); continue; }
                Unique(m.id);
                if (!Finite(m.x, m.z, m.yaw) || Math.Abs(m.yaw) > 1000000 || !Inside(g, m.x, m.z))
                    Error("MARKER", m.id, "Marker coordinates/yaw must be finite and within bounds.");
            }
            foreach (var r in world.roads)
            {
                if (r == null) { Error("ROAD", world.id, "Null road."); continue; }
                Unique(r.id);
                if (!Finite(r.width, r.clearance) || r.width <= 0 || r.width > 100 || r.clearance < 0 || r.clearance > 100 ||
                    r.points == null || r.points.Length < 2 || r.points.Length > 4096)
                { Error("ROAD", r.id, "Roads require 2–4096 points and finite, bounded width and clearance."); continue; }
                for (int i = 0; i < r.points.Length; i++)
                {
                    var p = r.points[i];
                    if (!Finite(p.x, p.z) || !Inside(g, p.x, p.z)) Error("ROAD_POINT", r.id, "Road centreline lies outside world bounds.");
                    if (i > 0 && Geometry.PointSegmentDistance(p, r.points[i - 1], r.points[i - 1]) < 0.01)
                        Error("ROAD_SEGMENT", r.id, "Consecutive road points must be distinct.");
                }
            }
            foreach (var o in world.objects)
            {
                if (o == null) { Error("OBJECT", world.id, "Null object."); continue; }
                Unique(o.id);
                if (o.asset == null || !assets.ContainsKey(o.asset)) Error("UNKNOWN_ASSET", o.id, "Asset ID is not registered.");
                if (!Finite(o.x, o.z, o.yaw, o.scale, o.groundOffset) || o.scale <= 0 || o.scale > 10 || Math.Abs(o.yaw) > 1000000 ||
                    Math.Abs(o.groundOffset) > 100 || !Inside(g, o.x, o.z))
                    Error("TRANSFORM", o.id, "Use finite in-bounds coordinates, uniform scale 0–10 and bounded offsets/yaw.");
                if (o.landmark == null || (o.landmark.Length > 0 && !landmarkIds.Contains(o.landmark)))
                    Error("UNKNOWN_LANDMARK", o.id, "Unknown landmark ID.");
            }
            if (errors.Count > 0) return errors;

            var terrain = new TerrainSampler(world);
            var byCell = new Dictionary<CellKey, List<ObjectSpec>>();
            var footprints = new Dictionary<string, Point2[]>(StringComparer.Ordinal);
            foreach (var o in world.objects.OrderBy(o => o.id, StringComparer.Ordinal))
            {
                var asset = assets[o.asset];
                var footprint = Geometry.Footprint(o, asset);
                var padded = Geometry.Footprint(o, asset, asset.clearance * 0.5);
                foreach (var lake in t.lakes)
                    if (WorldDesign.IntersectsLake(footprint, lake)) Error("WATER_PLACEMENT", o.id, "Footprint intersects reserved water/shoreline " + lake.id + ".");
                if (footprint.Any(p => !Inside(g, p.x, p.z))) Error("OUT_OF_BOUNDS", o.id, "Rotated footprint crosses the world boundary.");
                var probes = new List<Point2> { new Point2(o.x, o.z) };
                // Sample interiors as well as corners so a large foundation cannot hide a hill.
                int nx = Math.Max(2, (int)Math.Ceiling(asset.width * o.scale / t.gridSpacing));
                int nz = Math.Max(2, (int)Math.Ceiling(asset.depth * o.scale / t.gridSpacing));
                if ((long)nx * nz > 65536) { Error("FOOTPRINT_SIZE", o.id, "Foundation needs too many terrain probes."); continue; }
                for (int iz = 0; iz <= nz; iz++)
                    for (int ix = 0; ix <= nx; ix++)
                    {
                        double u = (double)ix / nx, v = (double)iz / nz;
                        probes.Add(new Point2(footprint[0].x + u * (footprint[1].x - footprint[0].x) + v * (footprint[3].x - footprint[0].x),
                            footprint[0].z + u * (footprint[1].z - footprint[0].z) + v * (footprint[3].z - footprint[0].z)));
                    }
                double min = double.PositiveInfinity, max = double.NegativeInfinity, slope = 0;
                foreach (var p in probes)
                { double y = terrain.Height(p.x, p.z); min = Math.Min(min, y); max = Math.Max(max, y); slope = Math.Max(slope, terrain.SlopeDegrees(p.x, p.z)); }
                if (slope > asset.maxSlopeDegrees + 1e-6) Error("SLOPE", o.id, "Footprint exceeds the asset's slope limit.");
                if (max - min > asset.maxRelief + 1e-6) Error("RELIEF", o.id, "Foundation height variation exceeds the asset's relief limit.");
                if (asset.blocksPlacement)
                {
                    foreach (var road in world.roads)
                        for (int i = 1; i < road.points.Length; i++)
                            if (Geometry.PolygonSegmentDistance(footprint, road.points[i - 1], road.points[i]) < road.width * 0.5 + road.clearance - 1e-6)
                            { Error("ROAD_CLEARANCE", o.id, "Footprint blocks " + road.id + " or its clearance."); break; }
                    var candidates = new HashSet<string>(StringComparer.Ordinal);
                    foreach (var key in Geometry.TouchedCells(g, padded))
                    {
                        if (!byCell.TryGetValue(key, out var neighbors)) { neighbors = new List<ObjectSpec>(); byCell.Add(key, neighbors); }
                        foreach (var other in neighbors)
                            if (candidates.Add(other.id) && Geometry.Overlaps(padded, footprints[other.id]))
                                Error("OVERLAP", o.id, "Footprint/clearance overlaps " + other.id + ".");
                        neighbors.Add(o);
                    }
                    footprints.Add(o.id, padded);
                }
            }
            if (errors.Count > 0) return errors;
            errors.AddRange(WorldDesign.CheckLayout(world, registry));
            if (errors.Count > 0) return errors;
            var plan = WorldCompiler.CompileValidated(world, registry);
            foreach (var cell in plan.cells)
            {
                var cost = cell.cost;
                if (cost.triangles > b.triangles || cost.materialSlots > b.materialSlots || cost.textureKiB > b.textureKiB ||
                    cost.colliders > b.colliders || cost.shadowCasters > b.shadowCasters || cell.references.Length > b.objects)
                    Error("CELL_BUDGET", cell.key.ToString(), "Conservative static placement/terrain estimate exceeds a per-cell budget.");
            }
            return errors;
        }

        public static bool Inside(GridSpec g, double x, double z)
        { return x >= g.originX && x <= g.originX + g.sizeX && z >= g.originZ && z <= g.originZ + g.sizeZ; }
        private static bool Multiple(double value, double step)
        { return step > 0 && Math.Abs(value / step - Math.Round(value / step)) < 1e-8; }
    }
}
