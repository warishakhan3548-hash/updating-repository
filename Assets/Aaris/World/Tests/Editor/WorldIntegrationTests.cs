using System.IO;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using WorldEditor = Aaris.World.Editor.UnityWorldCompiler;

namespace Aaris.World.Tests
{
    public sealed class WorldIntegrationTests
    {
        [Test]
        public void UnityJsonPreservesWorldFieldsAndDoubleCoordinates()
        {
            var world = WorldEditor.ReadWorld();
            var restored = JsonUtility.FromJson<WorldSpec>(JsonUtility.ToJson(world));
            Assert.That(restored.objects.Length, Is.EqualTo(world.objects.Length));
            Assert.That(restored.objects.Last().x, Is.EqualTo(world.objects.Last().x));
            Assert.That(restored.terrain.gridSpacing, Is.EqualTo(world.terrain.gridSpacing));
            Assert.That(WorldValidator.Validate(restored, WorldEditor.ReadRegistry()), Is.Empty);
        }

        [Test]
        public void GeneratedScenePreservesIdsHeightsAndCellOwnership()
        {
            WorldEditor.Compile();
            var world = WorldEditor.ReadWorld();
            var objects = Object.FindObjectsByType<WorldObjectIdentity>(FindObjectsSortMode.None);
            Assert.That(objects.Length, Is.EqualTo(world.objects.Length));
            Assert.That(objects.Select(o => o.objectId).Distinct().Count(), Is.EqualTo(objects.Length));
            var terrain = new TerrainSampler(world);
            foreach (var o in objects)
            {
                var source = world.objects.Single(s => s.id == o.objectId);
                Assert.That(o.transform.position.y, Is.EqualTo(terrain.Height(source.x, source.z) + source.groundOffset).Within(0.001));
                Assert.That(o.ownerCell, Is.EqualTo(WorldCompiler.CellAt(world.grid, source.x, source.z).ToString()));
                Assert.That(o.transform.parent.name, Is.EqualTo(o.ownerCell));
            }
            Assert.That(File.Exists(WorldEditor.ScenePath), Is.True);
            Assert.That(GraphicsSettings.defaultRenderPipeline, Is.Not.Null);
            Assert.That(AssetDatabase.LoadAssetAtPath<Mesh>(WorldEditor.Generated + "/Meshes/cell_0_0.asset"), Is.Not.Null);
        }

        [Test]
        public void GeneratedTerrainMeshMatchesGroundSampler()
        {
            WorldEditor.Compile();
            var world = WorldEditor.ReadWorld(); var sampler = new TerrainSampler(world);
            var mesh = AssetDatabase.LoadAssetAtPath<Mesh>(WorldEditor.Generated + "/Meshes/cell_0_0.asset");
            foreach (var vertex in mesh.vertices)
                Assert.That(vertex.y, Is.EqualTo(sampler.Height(world.grid.originX + vertex.x, world.grid.originZ + vertex.z)).Within(0.001));
            int segments = (int)System.Math.Round(world.grid.cellSize / world.terrain.gridSpacing);
            Assert.That(mesh.triangles.Length, Is.EqualTo(6 * segments * segments));
            Assert.That(mesh.indexFormat, Is.EqualTo(IndexFormat.UInt16),
                "Small terrain tiles should not pay the 32-bit index bandwidth cost.");
            Assert.That(mesh.normals.All(n => n.y > 0), Is.True);
        }

        [Test]
        public void RepeatedProceduralAssetsShareMeshesAndKeepThreeLods()
        {
            WorldEditor.Compile();
            var instances = Object.FindObjectsByType<WorldObjectIdentity>(FindObjectsSortMode.None)
                .Where(o => o.assetId == "courtyard_house").Take(2).ToArray();
            Assert.That(instances.Length, Is.EqualTo(2));
            var first = instances[0].GetComponentsInChildren<MeshFilter>(true);
            var second = instances[1].GetComponentsInChildren<MeshFilter>(true);
            Assert.That(first.Length, Is.EqualTo(second.Length));
            for (int i = 0; i < first.Length; i++) Assert.That(first[i].sharedMesh, Is.SameAs(second[i].sharedMesh));
            Assert.That(instances[0].GetComponent<LODGroup>().GetLODs().Length, Is.EqualTo(3));
            Assert.That(instances[0].GetComponent<MeshCollider>().sharedMesh, Is.SameAs(instances[1].GetComponent<MeshCollider>().sharedMesh));

            var tree = WorldEditor.ReadRegistry().assets.First(a => a.archetype == "oak" || a.archetype == "pine");
            var prefab = AssetDatabase.LoadAssetAtPath<GameObject>(WorldEditor.Generated + "/Templates/" + tree.id + ".prefab");
            Assert.That(prefab, Is.Not.Null);
            var leaves = prefab.GetComponentsInChildren<MeshRenderer>(true)
                .Where(r => r.sharedMaterial != null && r.sharedMaterial.name == tree.id + "_leaf").ToArray();
            Assert.That(leaves.Length, Is.GreaterThan(0));
            foreach (var leaf in leaves)
            {
                Assert.That(leaf.sharedMaterial.shader.name, Is.EqualTo("Aaris/Procedural Foliage"));
                Assert.That(leaf.sharedMaterial.enableInstancing, Is.True);
                Assert.That(leaf.sharedMaterial.GetFloat("_WindStrength"), Is.InRange(0.01f, 0.3f));
            }
            Assert.That(prefab.GetComponent<MeshCollider>(), Is.Not.Null,
                "Foliage animation must not replace the static trunk collider.");
        }

        [Test]
        public void FoliageWindShaderImportsWithoutCompilerErrors()
        {
            var shader = Shader.Find("Aaris/Procedural Foliage");
            Assert.That(shader, Is.Not.Null);
            Assert.That(ShaderUtil.ShaderHasError(shader), Is.False);
            Assert.That(shader.FindPassTagValue(0, new ShaderTagId("LightMode")).name,
                Is.EqualTo("UniversalForward"));
        }

        [Test]
        public void BiomeShaderImportsWithoutCompilerErrors()
        {
            var shader = Shader.Find("Aaris/Biome Terrain");
            Assert.That(shader, Is.Not.Null);
            Assert.That(ShaderUtil.ShaderHasError(shader), Is.False);
        }
    }
}
