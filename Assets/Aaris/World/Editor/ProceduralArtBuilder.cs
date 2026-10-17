using System;
using System.Collections.Generic;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

namespace Aaris.World.Editor
{
    // One template and one mesh/material per asset/LOD. Every placement reuses them.
    internal static class ProceduralArtBuilder
    {
        private static readonly Dictionary<string, Material> Materials = new Dictionary<string, Material>(StringComparer.Ordinal);
        private static readonly Dictionary<string, GameObject> Templates = new Dictionary<string, GameObject>(StringComparer.Ordinal);
        private static int resolution;

        public static void Prepare(AssetRegistry registry, int textureResolution, VisualSpec visuals)
        {
            if (visuals == null) throw new ArgumentNullException(nameof(visuals));
            Materials.Clear(); Templates.Clear(); resolution = textureResolution;
            System.IO.Directory.CreateDirectory(UnityWorldCompiler.Generated + "/Templates");
            System.IO.Directory.CreateDirectory(UnityWorldCompiler.Generated + "/Textures"); AssetDatabase.Refresh();
            foreach (var a in registry.assets.Where(a => !string.IsNullOrEmpty(a.archetype) && string.IsNullOrEmpty(a.prefabPath)))
            {
                var geometryLevels = Enumerable.Range(0, 3).Select(lod => ProceduralArt.Create(a, lod)).ToArray();
                var used = new HashSet<string>(geometryLevels.SelectMany(g => g.parts.Select(p => p.material)), StringComparer.Ordinal);
                foreach (var surface in ArtPalette.Surfaces(a).Where(s => used.Contains(s.id))) GetMaterial(surface);
                var root = new GameObject(a.id + "_ProceduralDevelopmentArt");
                bool isTree = a.archetype == "oak" || a.archetype == "pine";
                var windPivots = isTree ? new Transform[3] : null;
                var levels = new LOD[3];
                for (int lod = 0; lod < 3; lod++)
                {
                    var geometry = geometryLevels[lod];
                    var parent = new GameObject("LOD" + lod); parent.transform.SetParent(root.transform, false);
                    if (isTree)
                    {
                        var pivot = new GameObject("Canopy Wind Pivot").transform;
                        pivot.SetParent(parent.transform, false);
                        pivot.localPosition = Vector3.up * (float)(a.height * 0.54);
                        windPivots[lod] = pivot;
                    }
                    var renderers = new List<Renderer>();
                    for (int part = 0; part < geometry.parts.Length; part++)
                    {
                        var source = geometry.parts[part];
                        var mesh = Mesh(source, a.id + "_LOD" + lod + "_" + part);
                        AssetDatabase.CreateAsset(mesh, UnityWorldCompiler.Generated + "/Meshes/" + mesh.name + ".asset");
                        var go = new GameObject(source.material);
                        if (isTree && source.material == a.id + "_leaf")
                        {
                            go.transform.SetParent(windPivots[lod], false);
                            // Mesh coordinates stay in tree-root space at zero wind.
                            go.transform.localPosition = -windPivots[lod].localPosition;
                        }
                        else go.transform.SetParent(parent.transform, false);
                        go.AddComponent<MeshFilter>().sharedMesh = mesh;
                        var renderer = go.AddComponent<MeshRenderer>(); renderer.sharedMaterial = Materials[source.material];
                        renderer.shadowCastingMode = source.material == "glass" ? ShadowCastingMode.Off : ShadowCastingMode.On;
                        renderers.Add(renderer);
                    }
                    if (lod == 0 && geometry.collision.vertices.Length > 0)
                    {
                        var collision = Mesh(geometry.collision, a.id + "_collision");
                        AssetDatabase.CreateAsset(collision, UnityWorldCompiler.Generated + "/Meshes/" + collision.name + ".asset");
                        root.AddComponent<MeshCollider>().sharedMesh = collision;
                    }
                    // Last LOD keeps a silhouette until far-clip; collision never disappears at an LOD switch.
                    levels[lod] = new LOD(lod == 0 ? 0.12f : lod == 1 ? 0.035f : 0, renderers.ToArray());
                }
                var group = root.AddComponent<LODGroup>(); group.fadeMode = LODFadeMode.None;
                group.SetLODs(levels); group.RecalculateBounds();
                if (isTree && visuals.windEnabled && visuals.windAngleDegrees > 0)
                {
                    var wind = root.AddComponent<FoliageWind>();
                    wind.canopyPivots = windPivots;
                    wind.frequencyHz = (float)visuals.windFrequencyHz;
                    wind.maximumDegrees = (float)visuals.windAngleDegrees;
                    wind.activeDistance = (float)visuals.windActiveDistance;
                }
                var template = PrefabUtility.SaveAsPrefabAsset(root, UnityWorldCompiler.Generated + "/Templates/" + a.id + ".prefab");
                Templates.Add(a.id, template); Object.DestroyImmediate(root);
            }
        }

        public static GameObject Instantiate(AssetSpec asset)
        { return (GameObject)PrefabUtility.InstantiatePrefab(Templates[asset.id]); }

        public static Mesh Mesh(ArtMesh source, string name)
        {
            var mesh = new Mesh { name = name, indexFormat = IndexFormat.UInt32 };
            mesh.vertices = source.vertices.Select(v => new Vector3(v.x, v.y, v.z)).ToArray();
            mesh.uv = source.vertices.Select(v => new Vector2(v.u, v.v)).ToArray();
            mesh.colors32 = source.vertices.Select(v => new Color32(v.r, v.g, v.b, 255)).ToArray();
            mesh.triangles = source.triangles;
            mesh.RecalculateNormals(); mesh.RecalculateTangents(); mesh.RecalculateBounds();
            return mesh;
        }

        public static Material GetMaterial(PbrSurface surface)
        {
            if (Materials.TryGetValue(surface.id, out var material)) return material;
            string shaderName = surface.id == "terrain" ? "Aaris/Biome Terrain" : "Universal Render Pipeline/Lit";
            var shader = Shader.Find(shaderName);
            if (shader == null) throw new InvalidOperationException("Missing shader: " + shaderName);
            material = new Material(shader) { name = surface.id, enableInstancing = true };
            material.SetColor("_BaseColor", Color.white);
            if (material.HasProperty("_Smoothness")) material.SetFloat("_Smoothness", (float)(1 - surface.roughness));
            if (material.HasProperty("_Metallic")) material.SetFloat("_Metallic", (float)surface.metallic);
            var albedo = new Texture2D(resolution, resolution, TextureFormat.RGBA32, true, false) { name = surface.id + "_albedo", wrapMode = TextureWrapMode.Repeat, anisoLevel = 2 };
            albedo.LoadRawTextureData(ArtPalette.Albedo(surface, resolution)); albedo.Apply(true, false);
            AssetDatabase.CreateAsset(albedo, UnityWorldCompiler.Generated + "/Textures/" + albedo.name + ".asset");
            material.SetTexture("_BaseMap", albedo);
            if (surface.bump > 0)
            {
                var normal = new Texture2D(resolution, resolution, TextureFormat.RGBA32, true, true) { name = surface.id + "_normal", wrapMode = TextureWrapMode.Repeat, anisoLevel = 2 };
                var pixels = new Color32[resolution * resolution]; double step = 1.0 / resolution;
                for (int y = 0; y < resolution; y++) for (int x = 0; x < resolution; x++)
                {
                    double u = (double)x / resolution, v = (double)y / resolution;
                    float dx = (float)((ArtPalette.Height(surface.pattern, u + step, v) - ArtPalette.Height(surface.pattern, u - step, v)) * surface.bump * 12);
                    float dy = (float)((ArtPalette.Height(surface.pattern, u, v + step) - ArtPalette.Height(surface.pattern, u, v - step)) * surface.bump * 12);
                    var n = new Vector3(-dx, -dy, 1).normalized;
                    pixels[y * resolution + x] = new Color32((byte)((n.x * 0.5f + 0.5f) * 255), (byte)((n.y * 0.5f + 0.5f) * 255), (byte)((n.z * 0.5f + 0.5f) * 255), 255);
                }
                normal.SetPixels32(pixels); normal.Apply(true, false);
                AssetDatabase.CreateAsset(normal, UnityWorldCompiler.Generated + "/Textures/" + normal.name + ".asset");
                material.SetTexture("_BumpMap", normal); material.SetFloat("_BumpScale", 1); material.EnableKeyword("_NORMALMAP");
            }
            AssetDatabase.CreateAsset(material, UnityWorldCompiler.Generated + "/Materials/" + surface.id + ".asset");
            Materials.Add(surface.id, material); return material;
        }
    }
}
