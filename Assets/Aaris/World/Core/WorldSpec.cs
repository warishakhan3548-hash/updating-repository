using System;

namespace Aaris.World
{
    // Fields deliberately match Unity JsonUtility and System.Text.Json IncludeFields.
    // Metres; +Y up; +Z north; yaw is Unity's clockwise rotation around +Y.
    [Serializable]
    public sealed class WorldSpec
    {
        public int schemaVersion = 1;
        public string id = "";
        public int revision = 1;
        public int seed = 1701;
        public GridSpec grid = new GridSpec();
        public TerrainSpec terrain = new TerrainSpec();
        public BudgetSpec budget = new BudgetSpec();
        public StreamingSpec streaming = new StreamingSpec();
        public RoadSpec[] roads = Array.Empty<RoadSpec>();
        public LandmarkSpec[] landmarks = Array.Empty<LandmarkSpec>();
        public MarkerSpec[] markers = Array.Empty<MarkerSpec>();
        public ObjectSpec[] objects = Array.Empty<ObjectSpec>();
        public BiomeSpec[] biomes = Array.Empty<BiomeSpec>();
        public RouteSpec[] routes = Array.Empty<RouteSpec>();
        public DesignSpec design = new DesignSpec();
        public VisualSpec visuals = new VisualSpec();
    }

    [Serializable]
    public sealed class GridSpec
    {
        public double originX = -512;
        public double originZ = -512;
        public double sizeX = 1024;
        public double sizeZ = 1024;
        public double cellSize = 128;
    }

    [Serializable]
    public sealed class TerrainSpec
    {
        public double baseHeight = 4;
        public double amplitude = 12;
        public double noiseScale = 180;
        public int octaves = 3;
        public double gridSpacing = 8;
        public TerrainPad[] pads = Array.Empty<TerrainPad>();
        public HillSpec[] hills = Array.Empty<HillSpec>();
        public LakeSpec[] lakes = Array.Empty<LakeSpec>();
    }

    [Serializable]
    public sealed class TerrainPad
    {
        public double x;
        public double z;
        public double height;
        public double radius = 40;
        public double blend = 24;
    }

    [Serializable]
    public sealed class BudgetSpec
    {
        // Conservative authoring estimates per cell, not GPU timings/draw calls.
        public long triangles = 120000;
        public long materialSlots = 200;
        public long textureKiB = 65536;
        public long colliders = 160;
        public long shadowCasters = 160;
        public int objects = 128;
    }

    [Serializable]
    public sealed class StreamingSpec
    {
        public double loadRadius = 192;
        public double unloadRadius = 256;
        public int maxResidentCells = 32;
    }

    [Serializable]
    public sealed class RoadSpec
    {
        public string id = "";
        public double width = 10;
        public double clearance = 3;
        public Point2[] points = Array.Empty<Point2>();
    }

    [Serializable]
    public struct Point2
    {
        public double x;
        public double z;
        public Point2(double x, double z) { this.x = x; this.z = z; }
    }

    [Serializable]
    public sealed class LandmarkSpec
    {
        public string id = "";
        public string name = "";
        public double x;
        public double z;
        public double radius = 60;
        public int minBuildings;
        public int maxBuildings = 100;
        public int minApproaches;
    }

    [Serializable]
    public sealed class MarkerSpec
    {
        public string id = "";
        public double x;
        public double z;
        public double yaw;
    }

    [Serializable]
    public sealed class ObjectSpec
    {
        public string id = "";
        public string asset = "";
        public string landmark = "";
        public double x;
        public double z;
        public double yaw;
        public double scale = 1;
        // Ground is sampled, not copied into editable JSON as a stale Y coordinate.
        public double groundOffset;
    }

    [Serializable]
    public sealed class AssetRegistry
    {
        public int schemaVersion = 1;
        public AssetSpec[] assets = Array.Empty<AssetSpec>();
    }

    [Serializable]
    public sealed class AssetSpec
    {
        public string id = "";
        // Empty means an explicitly labelled architectural blockout, never final art.
        public string prefabPath = "";
        public string previewShape = "building";
        public string color = "#d5b889";
        public string source = "Original Aaris architectural blockout";
        public string license = "Project-owned";
        public double width = 12;
        public double depth = 10;
        public double height = 7;
        public double clearance = 2;
        public double maxSlopeDegrees = 12;
        public double maxRelief = 1.5;
        public bool blocksPlacement = true;
        public long triangles = 1000;
        public long materialSlots = 2;
        public long textureKiB = 0;
        public long colliders = 1;
        public long shadowCasters = 1;
        // Empty preserves v1 blockouts. A v2 archetype is original procedural development art.
        public string archetype = "";
        public string roofColor = "#874b35";
        public bool providesCover;
        public int artSeed = 1701;
    }

    [Serializable]
    public sealed class HillSpec
    {
        public double x;
        public double z;
        public double radius = 100;
        public double height = 25;
    }

    [Serializable]
    public sealed class LakeSpec
    {
        public string id = "";
        public double x;
        public double z;
        public double radiusX = 70;
        public double radiusZ = 45;
        public double surfaceY = 4;
        public double depth = 5;
        public double blend = 0.5;
    }

    [Serializable]
    public sealed class BiomeSpec
    {
        public string id = "";
        public string kind = "meadow";
        public double x;
        public double z;
        public double radiusX = 100;
        public double radiusZ = 100;
        public string color = "#7d935b";
        public int minTrees;
        public int maxTrees = 100;
    }

    [Serializable]
    public sealed class RouteSpec
    {
        public string id = "";
        public string from = "";
        public string to = "";
        public Point2[] points = Array.Empty<Point2>();
        public double width = 4;
        public double maxCoverGap = 65;
        public double coverSearchRadius = 26;
        public double maxSlopeDegrees = 25;
    }

    [Serializable]
    public sealed class DesignSpec
    {
        public bool enabled;
        public int maxTotalBuildings = 100;
        public int maxBuildingsPerCell = 12;
        public int maxTreesPerCell = 36;
        public double maxCellFootprintRatio = 0.3;
        public double maxWorldBuildingRatio = 0.06;
        public double minLandmarkSeparation = 120;
        public bool requireRedundantRoutes = true;
    }

    [Serializable]
    public sealed class VisualSpec
    {
        public double sunYaw = -35;
        public double sunPitch = 42;
        public double sunIntensity = 1.5;
        public double shadowDistance = 110;
        public double fogDensity = 0.0007;
        public string fogColor = "#aabeca";
        public int textureResolution = 128;
        public bool windEnabled = true;
        public double windAngleDegrees = 2.4;
        public double windFrequencyHz = 0.18;
        public double windActiveDistance = 260;
    }
}
