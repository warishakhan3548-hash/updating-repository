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
            if (world.terrain.lakes.Length > 0)
            {
                var lake = AssetDatabase.LoadAssetAtPath<Material>(WorldEditor.Generated + "/Materials/LakeWater.asset");
                Assert.That(lake, Is.Not.Null);
                Assert.That(lake.shader.name, Is.EqualTo("Aaris/Lake Water"));
            }
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
        }

        [Test]
        public void EnvironmentShadersImportWithoutCompilerErrors()
        {
            foreach (var name in new[] { "Aaris/Biome Terrain", "Aaris/Lake Water" })
            {
                var shader = Shader.Find(name);
                Assert.That(shader, Is.Not.Null, name + " must import before generating a scene.");
                Assert.That(ShaderUtil.ShaderHasError(shader), Is.False, name + " failed shader compilation.");
            }
        }
    }
}
