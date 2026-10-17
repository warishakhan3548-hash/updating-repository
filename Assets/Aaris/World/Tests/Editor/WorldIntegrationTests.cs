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
            Assert.That(mesh.normals.All(n => n.y > 0), Is.True);
        }
    }
}
