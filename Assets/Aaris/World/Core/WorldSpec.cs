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
    }
}
