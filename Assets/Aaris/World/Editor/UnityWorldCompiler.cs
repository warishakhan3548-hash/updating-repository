using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using Object = UnityEngine.Object;

namespace Aaris.World.Editor
{
    public static class UnityWorldCompiler
    {
        public const string Generated = "Assets/Generated";
        public const string ScenePath = Generated + "/WorldReview.unity";
        public const string Source = "Assets/GameData/World/world.json";
        public const string Registry = "Assets/GameData/World/assets.json";

        public static WorldSpec ReadWorld() { return JsonUtility.FromJson<WorldSpec>(File.ReadAllText(Source)); }
        public static AssetRegistry ReadRegistry() { return JsonUtility.FromJson<AssetRegistry>(File.ReadAllText(Registry)); }

        [MenuItem("Aaris/World/Validate Source (No APK)")]
        public static void ValidateSource()
        {
            var errors = WorldValidator.Validate(ReadWorld(), ReadRegistry());
            if (errors.Count > 0) throw new InvalidDataException(string.Join("\n", errors));
            Debug.Log("Aaris world source validated. No player build requested.");
        }

        [MenuItem("Aaris/World/Compile Review Scene (No APK)")]
        public static void Compile()
        {
            var world = ReadWorld(); var registry = ReadRegistry();
            var plan = WorldCompiler.Compile(world, registry);
            // Preserve unsaved human work before replacing the editor's active review scene.
            if (!Application.isBatchMode && !EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo())
                throw new OperationCanceledException("Scene compilation was cancelled before changing the active scene.");
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            if (AssetDatabase.IsValidFolder(Generated)) AssetDatabase.DeleteAsset(Generated);
            Directory.CreateDirectory(Generated + "/Meshes");
            Directory.CreateDirectory(Generated + "/Materials");
            AssetDatabase.Refresh();
            ConfigureProject();
            var assets = registry.assets.ToDictionary(a => a.id, StringComparer.Ordinal);
            var materials = new Dictionary<string, Material>(StringComparer.Ordinal);
            var cells = new Dictionary<CellKey, Transform>();
            var terrain = new TerrainSampler(world);
            var ground = Material("Terrain", new Color(0.22f, 0.34f, 0.25f));
            foreach (var cell in plan.cells)
            {
                var root = new GameObject(cell.key.ToString()).transform;
                cells.Add(cell.key, root);
                var mesh = TerrainMesh(world, cell.key, terrain);
                AssetDatabase.CreateAsset(mesh, Generated + "/Meshes/" + cell.key + ".asset");
                var tile = new GameObject("Terrain"); tile.transform.SetParent(root, false);
                tile.transform.position = new Vector3((float)(world.grid.originX + cell.key.x * world.grid.cellSize), 0,
                    (float)(world.grid.originZ + cell.key.z * world.grid.cellSize));
                tile.AddComponent<MeshFilter>().sharedMesh = mesh;
                tile.AddComponent<MeshRenderer>().sharedMaterial = ground;
                tile.AddComponent<MeshCollider>().sharedMesh = mesh;
                tile.isStatic = true;
            }
            foreach (var o in plan.objects)
            {
                var a = assets[o.asset];
                GameObject instance;
                if (!string.IsNullOrEmpty(a.prefabPath))
                {
                    var prefab = AssetDatabase.LoadAssetAtPath<GameObject>(a.prefabPath);
                    if (prefab == null) throw new InvalidDataException("Missing prefab: " + a.prefabPath);
                    instance = (GameObject)PrefabUtility.InstantiatePrefab(prefab);
                }
                else
                {
                    if (!materials.TryGetValue(a.id, out var material))
                    {
                        if (!ColorUtility.TryParseHtmlString(a.color, out var color)) throw new InvalidDataException("Invalid color: " + a.id);
                        material = Material(a.id, color); materials.Add(a.id, material);
                    }
                    instance = ArchitecturalBlockout.Create(a, material);
                }
                instance.name = o.id;
                instance.transform.SetParent(cells[o.owner], false);
                instance.transform.SetPositionAndRotation(new Vector3((float)o.x, (float)o.y, (float)o.z), Quaternion.Euler(0, (float)o.yaw, 0));
                instance.transform.localScale = Vector3.one * (float)o.scale;
                var identity = instance.GetComponent<WorldObjectIdentity>() ?? instance.AddComponent<WorldObjectIdentity>();
                identity.objectId = o.id; identity.assetId = o.asset;
                identity.ownerCell = o.owner.ToString(); identity.worldRevision = world.revision;
            }
            MakeRoads(world, terrain);
            var sun = new GameObject("Sun").AddComponent<Light>();
            sun.type = LightType.Directional; sun.intensity = 1.5f;
            sun.shadows = LightShadows.Soft; sun.transform.rotation = Quaternion.Euler(48, -35, 0);
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = new Color(0.45f, 0.52f, 0.62f);
            var skyShader = Shader.Find("Skybox/Procedural");
            if (skyShader != null)
            {
                var sky = new Material(skyShader); AssetDatabase.CreateAsset(sky, Generated + "/Materials/Sky.asset");
                RenderSettings.skybox = sky;
            }
            var camera = new GameObject("Review Camera").AddComponent<Camera>();
            camera.tag = "MainCamera"; camera.farClipPlane = 3000;
            camera.transform.position = new Vector3(0, 700, -650);
            camera.transform.LookAt(new Vector3(0, 5, 0));
            File.WriteAllText(Generated + "/world-plan.json", JsonUtility.ToJson(plan, true));
            AssetDatabase.Refresh(); AssetDatabase.SaveAssets();
            if (!EditorSceneManager.SaveScene(EditorSceneManager.GetActiveScene(), ScenePath))
                throw new IOException("Unable to save generated review scene.");
            Debug.Log("Compiled " + plan.objects.Length + " placements in " + plan.cells.Length + " cell groups. Full review scene only; runtime streaming and Android builds are not run.");
        }

        private static void ConfigureProject()
        {
            EditorSettings.serializationMode = SerializationMode.ForceText;
            PlayerSettings.colorSpace = ColorSpace.Linear;
            var renderer = ScriptableObject.CreateInstance<UniversalRendererData>();
            AssetDatabase.CreateAsset(renderer, Generated + "/Renderer.asset");
            var pipeline = UniversalRenderPipelineAsset.Create(renderer);
            pipeline.msaaSampleCount = 2; pipeline.shadowDistance = 100; pipeline.renderScale = 1;
            pipeline.supportsHDR = false;
            AssetDatabase.CreateAsset(pipeline, Generated + "/MobileURP.asset");
            GraphicsSettings.defaultRenderPipeline = pipeline;
            QualitySettings.renderPipeline = pipeline;
        }

        private static Material Material(string name, Color color)
        {
            var shader = Shader.Find("Universal Render Pipeline/Lit");
            if (shader == null) throw new InvalidOperationException("URP Lit shader is missing; restore pinned packages first.");
            var result = new Material(shader) { name = name, enableInstancing = true };
            result.SetColor("_BaseColor", color); result.SetFloat("_Smoothness", 0.15f);
            AssetDatabase.CreateAsset(result, Generated + "/Materials/" + name + ".asset");
            return result;
        }

        private static Mesh TerrainMesh(WorldSpec world, CellKey key, TerrainSampler terrain)
        {
            int n = (int)Math.Round(world.grid.cellSize / world.terrain.gridSpacing), side = n + 1;
            float step = (float)world.terrain.gridSpacing;
            double minX = world.grid.originX + key.x * world.grid.cellSize;
            double minZ = world.grid.originZ + key.z * world.grid.cellSize;
            var vertices = new Vector3[side * side]; var uv = new Vector2[vertices.Length];
            for (int z = 0; z <= n; z++)
                for (int x = 0; x <= n; x++)
                {
                    vertices[z * side + x] = new Vector3(x * step, (float)terrain.VertexHeight(minX + x * step, minZ + z * step), z * step);
                    uv[z * side + x] = new Vector2((float)(minX + x * step) / 32, (float)(minZ + z * step) / 32);
                }
            var triangles = new int[n * n * 6]; int cursor = 0;
            for (int z = 0; z < n; z++)
                for (int x = 0; x < n; x++)
                {
                    int a = z * side + x, b = a + 1, c = a + side, d = c + 1;
                    triangles[cursor++] = a; triangles[cursor++] = c; triangles[cursor++] = b;
                    triangles[cursor++] = b; triangles[cursor++] = c; triangles[cursor++] = d;
                }
            var mesh = new Mesh { name = key.ToString(), vertices = vertices, uv = uv, triangles = triangles };
            // Use global height gradients so normals agree on opposite sides of a cell seam.
            var normals = new Vector3[vertices.Length];
            for (int z = 0; z <= n; z++)
                for (int x = 0; x <= n; x++)
                {
                    double wx = minX + x * step, wz = minZ + z * step;
                    float dx = (float)(terrain.VertexHeight(wx + 0.25, wz) - terrain.VertexHeight(wx - 0.25, wz));
                    float dz = (float)(terrain.VertexHeight(wx, wz + 0.25) - terrain.VertexHeight(wx, wz - 0.25));
                    normals[z * side + x] = new Vector3(-dx, 0.5f, -dz).normalized;
                }
            mesh.normals = normals; mesh.RecalculateBounds(); return mesh;
        }

        private static void MakeRoads(WorldSpec world, TerrainSampler terrain)
        {
            var root = new GameObject("Roads - review surfaces only").transform;
            var material = Material("Road", new Color(0.25f, 0.28f, 0.29f));
            foreach (var road in world.roads)
            {
                var vertices = new List<Vector3>(); var triangles = new List<int>();
                for (int i = 1; i < road.points.Length; i++)
                {
                    var a = road.points[i - 1]; var b = road.points[i];
                    double dx = b.x - a.x, dz = b.z - a.z, length = Math.Sqrt(dx * dx + dz * dz);
                    int count = Math.Max(1, (int)Math.Ceiling(length / world.terrain.gridSpacing));
                    double ox = -dz / length * road.width * 0.5, oz = dx / length * road.width * 0.5;
                    for (int j = 0; j < count; j++)
                    {
                        double u = (double)j / count, v = (double)(j + 1) / count;
                        int start = vertices.Count;
                        foreach (var p in new[] { new Point2(a.x + dx * u - ox, a.z + dz * u - oz), new Point2(a.x + dx * u + ox, a.z + dz * u + oz),
                            new Point2(a.x + dx * v - ox, a.z + dz * v - oz), new Point2(a.x + dx * v + ox, a.z + dz * v + oz) })
                            vertices.Add(new Vector3((float)p.x, (float)terrain.Height(p.x, p.z) + 0.08f, (float)p.z));
                        triangles.AddRange(new[] { start, start + 1, start + 2, start + 1, start + 3, start + 2 });
                    }
                }
                var mesh = new Mesh { name = road.id, indexFormat = IndexFormat.UInt32, vertices = vertices.ToArray(), triangles = triangles.ToArray() };
                mesh.RecalculateNormals(); mesh.RecalculateBounds();
                AssetDatabase.CreateAsset(mesh, Generated + "/Meshes/" + road.id + ".asset");
                var go = new GameObject(road.id); go.transform.SetParent(root, false);
                go.AddComponent<MeshFilter>().sharedMesh = mesh; go.AddComponent<MeshRenderer>().sharedMaterial = material;
                // Terrain remains the collider: road cut/fill, junctions and final collision are a later stage.
            }
        }
    }
}
