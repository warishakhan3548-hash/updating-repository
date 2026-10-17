using System;
using System.Collections.Generic;
using System.Linq;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Aaris.World.Tests
{
    // These run the actual native Unity physics scene. They are NOT part of .NET self-test.
    public sealed class PhysicsIntegrationTests
    {
        private Scene scene;
        private PhysicsScene physics;
        private Vector3 gravity;
        private readonly List<PhysicsMaterial> materials = new List<PhysicsMaterial>();
        private bool playerWorldIgnored;
        [SetUp]
        public void SetUp()
        {
            gravity = Physics.gravity; Physics.gravity = Vector3.down * 9.81f;
            playerWorldIgnored = Physics.GetIgnoreLayerCollision(SandboxLayers.Player, SandboxLayers.World);
            Physics.IgnoreLayerCollision(SandboxLayers.Player, SandboxLayers.World, false);
            scene = SceneManager.CreateScene("AarisPhysicsTest_" + Guid.NewGuid().ToString("N"), new CreateSceneParameters(LocalPhysicsMode.Physics3D));
            physics = scene.GetPhysicsScene();
        }
        [TearDown]
        public void TearDown()
        {
            if (scene.IsValid()) EditorSceneManager.CloseScene(scene, true);
            Physics.gravity = gravity; Physics.IgnoreLayerCollision(SandboxLayers.Player, SandboxLayers.World, playerWorldIgnored);
            foreach (var material in materials) Object.DestroyImmediate(material); materials.Clear();
        }
        private GameObject Box(Vector3 centre, Vector3 size)
        {
            var go = GameObject.CreatePrimitive(PrimitiveType.Cube); SceneManager.MoveGameObjectToScene(go, scene);
            go.layer = SandboxLayers.World; go.transform.position = centre; go.transform.localScale = size; return go;
        }
        private PhysicsMaterial Surface(float friction)
        {
            var material = new PhysicsMaterial { staticFriction = friction, dynamicFriction = friction, bounciness = 0,
                frictionCombine = PhysicsMaterialCombine.Minimum, bounceCombine = PhysicsMaterialCombine.Minimum };
            materials.Add(material); return material;
        }
        private PhysicsPawn Pawn()
        {
            var go = new GameObject("Pawn"); SceneManager.MoveGameObjectToScene(go, scene); go.layer = SandboxLayers.Player;
            go.transform.position = Vector3.up * 0.05f;
            var pawn = go.AddComponent<PhysicsPawn>(); pawn.Configure();
            pawn.GetComponent<Collider>().sharedMaterial = Surface(0); pawn.Body.interpolation = RigidbodyInterpolation.None;
            return pawn;
        }
        private void Simulate(int steps, PhysicsPawn pawn = null, Vector2 move = default, bool sprint = false, int jumpAt = -1)
        {
            Physics.SyncTransforms();
            for (int i = 0; i < steps; i++) { if (pawn != null) pawn.Step(move, 0, sprint, i == jumpAt, 0.02f, i * 0.02); physics.Simulate(0.02f); }
        }
        private void Floor() { Box(new Vector3(0, -0.5f, 0), new Vector3(100, 1, 100)); }

        [Test]
        public void NativeGravityDropsABoxAndFloorStopsIt()
        {
            Floor(); var go = Box(new Vector3(0, 3, 0), Vector3.one); var body = go.AddComponent<Rigidbody>();
            body.collisionDetectionMode = CollisionDetectionMode.ContinuousDynamic;
            Simulate(150);
            Assert.That(body.position.y, Is.EqualTo(0.5f).Within(0.06)); Assert.That(Mathf.Abs(body.linearVelocity.y), Is.LessThan(0.15));
        }
        [Test]
        public void NativeFrictionSlowsAPhysicsProp()
        {
            var surface = Surface(0.8f);
            var floor = Box(new Vector3(0, -0.5f, 0), new Vector3(100, 1, 100)); floor.GetComponent<Collider>().sharedMaterial = surface;
            var go = Box(new Vector3(0, 0.51f, 0), Vector3.one); go.GetComponent<Collider>().sharedMaterial = surface;
            var body = go.AddComponent<Rigidbody>(); body.linearDamping = 0; body.linearVelocity = Vector3.right * 3;
            Simulate(150); Assert.That(Mathf.Abs(body.linearVelocity.x), Is.LessThan(0.2));
        }
        [Test]
        public void DiagonalMovementCannotExceedConfiguredWalkSpeed()
        {
            Floor(); var pawn = Pawn(); Simulate(100, pawn, Vector2.one);
            Assert.That(new Vector2(pawn.Body.linearVelocity.x, pawn.Body.linearVelocity.z).magnitude, Is.EqualTo(pawn.settings.walkSpeed).Within(0.3));
        }
        [Test]
        public void NativeWallStopsASprintingPawn()
        {
            Floor(); Box(new Vector3(0, 2, 3), new Vector3(12, 4, 0.2f)); var pawn = Pawn();
            Simulate(150, pawn, Vector2.up, true); Assert.That(pawn.Body.position.z, Is.LessThan(2.7f)); Assert.That(pawn.Body.position.y, Is.GreaterThan(-0.1));
        }
        [Test]
        public void SteepRampFaceCannotBeReclassifiedAsWalkableByASphereSweep()
        {
            var ramp = Box(Vector3.zero, new Vector3(10, 0.3f, 10)); ramp.transform.rotation = Quaternion.Euler(60, 0, 0);
            var pawn = Pawn(); pawn.Teleport(Vector3.up * 2); Physics.SyncTransforms(); bool sawSteepFace = false;
            for (int i = 0; i < 30; i++)
            {
                pawn.Step(Vector2.zero, 0, false, false, 0.02f, i * 0.02); physics.Simulate(0.02f);
                if (pawn.GroundNormal.y > 0.1f && pawn.GroundNormal.y < 0.6f) { sawSteepFace = true; Assert.That(pawn.Grounded, Is.False); }
            }
            Assert.That(sawSteepFace, Is.True);
        }
        [Test]
        public void JumpUsesNativeGravityAndCannotBeRepeatedInMidair()
        {
            Floor(); var pawn = Pawn(); Physics.SyncTransforms(); float apex = 0;
            for (int i = 0; i < 110; i++)
            {
                pawn.Step(Vector2.zero, 0, false, i == 10 || i == 20, 0.02f, i * 0.02); physics.Simulate(0.02f);
                apex = Mathf.Max(apex, pawn.Body.position.y);
            }
            Assert.That(apex, Is.InRange(1.0f, 1.4f)); Assert.That(pawn.Body.position.y, Is.EqualTo(0).Within(0.1));
        }
        [Test]
        public void CameraSeeingTargetDoesNotLetMuzzleShootThroughCover()
        {
            var cover = Box(new Vector3(0, 1.5f, 1), new Vector3(1, 3, 0.2f));
            Box(new Vector3(1.5f, 1.5f, 12), Vector3.one); Physics.SyncTransforms();
            var shot = PhysicsWeapon.Trace(physics, new Vector3(1.5f, 1.5f, 0), Vector3.forward, new Vector3(0, 1.35f, 0), new Vector3(0, 1.35f, 0.66f), 100, new Collider[1]);
            Assert.That(shot.hit, Is.True); Assert.That(shot.contact.collider.gameObject, Is.SameAs(cover));
        }
        [Test]
        public void BarrelInsideAWallCannotStartAShotBeyondIt()
        {
            var cover = Box(new Vector3(0, 1.5f, 0.55f), new Vector3(1, 3, 0.2f)); Physics.SyncTransforms();
            var shot = PhysicsWeapon.Trace(physics, new Vector3(1.5f, 1.5f, 0), Vector3.forward, new Vector3(0, 1.35f, 0), new Vector3(0, 1.35f, 0.66f), 100, new Collider[1]);
            Assert.That(shot.hit, Is.True); Assert.That(shot.contact.collider.gameObject, Is.SameAs(cover));
        }
        [Test]
        public void ChestInsideSolidGeometryRejectsTheShot()
        {
            Box(new Vector3(0, 1.35f, 0), Vector3.one); Physics.SyncTransforms();
            var shot = PhysicsWeapon.Trace(physics, Vector3.up * 2, Vector3.forward, Vector3.up * 1.35f, new Vector3(0, 1.35f, 1), 100, new Collider[1]);
            Assert.That(shot.blockedAtOrigin, Is.True); Assert.That(shot.hit, Is.False);
        }
        [Test]
        public void CameraInitialOverlapIsRejectedBeforeSweeping()
        {
            Box(Vector3.zero, Vector3.one); Physics.SyncTransforms();
            Assert.That(CameraCollision.TryLimit(physics, Vector3.zero, Vector3.back * 4, new Collider[8], out _), Is.False);
        }
        [Test]
        public void CameraVolumeStopsBeforeTheWallAndStaysOutsideIt()
        {
            Box(new Vector3(0, 1, -3), new Vector3(10, 6, 0.2f)); Physics.SyncTransforms();
            Vector3 pivot = Vector3.up, offset = Vector3.back * 4; var buffer = new Collider[8];
            Assert.That(CameraCollision.TryLimit(physics, pivot, offset, buffer, out float distance), Is.True);
            Assert.That(distance, Is.InRange(2.5f, 2.72f));
            Assert.That(physics.OverlapSphere(pivot + offset.normalized * distance, CameraCollision.Radius, buffer, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore), Is.EqualTo(0));
        }
        [Test]
        public void ClearCameraVolumeKeepsItsRequestedDistance()
        {
            Assert.That(CameraCollision.TryLimit(physics, Vector3.up * 3, new Vector3(0.6f, 0, -3.7f), new Collider[8], out float distance), Is.True);
            Assert.That(distance, Is.EqualTo(new Vector3(0.6f, 0, -3.7f).magnitude).Within(0.0001));
        }
        [Test]
        public void CameraAimPointBehindTheMuzzleCannotProduceABackwardShot()
        {
            Box(new Vector3(1.5f, 1.5f, 0.3f), new Vector3(0.4f, 2, 0.1f)); Physics.SyncTransforms();
            var shot = PhysicsWeapon.Trace(physics, new Vector3(1.5f, 1.5f, 0), Vector3.forward, new Vector3(0, 1.35f, 0), new Vector3(0, 1.35f, 0.66f), 100, new Collider[1]);
            Assert.That(shot.blockedAtOrigin, Is.True); Assert.That(shot.hit, Is.False);
        }
        [Test]
        public void NativeRoofQueryHitsTheSolidUnderside()
        {
            var asset = Aaris.World.Editor.UnityWorldCompiler.ReadRegistry().assets.First(a => a.archetype == "house");
            var model = ProceduralArt.Create(asset, 0).collision;
            var mesh = new Mesh { vertices = model.vertices.Select(v => new Vector3(v.x, v.y, v.z)).ToArray(), triangles = model.triangles };
            var go = new GameObject("Roof collider"); SceneManager.MoveGameObjectToScene(go, scene); go.layer = SandboxLayers.World;
            try
            {
                go.AddComponent<MeshCollider>().sharedMesh = mesh; Physics.SyncTransforms();
                float bodyHeight = (float)(asset.height - Math.Min(asset.height * 0.25, 2.4));
                Assert.That(physics.Raycast(new Vector3((float)asset.width * 0.2f, bodyHeight + 0.02f, 0), Vector3.up, out var hit, 4, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore), Is.True);
                Assert.That(hit.normal.y, Is.LessThan(-0.1f));
            }
            finally { Object.DestroyImmediate(go); Object.DestroyImmediate(mesh); }
        }
        [Test]
        public void TargetDeathDisablesCollisionAndResetRestoresHealth()
        {
            var go = Box(new Vector3(0, 1, 0), Vector3.one); var target = go.AddComponent<Damageable>(); target.ResetHealth();
            Assert.That(target.Apply(25), Is.True); Assert.That(target.Health, Is.EqualTo(75)); target.Apply(100);
            Assert.That(target.Dead, Is.True); Assert.That(go.GetComponent<Collider>().enabled, Is.False); Assert.That(target.Apply(25), Is.False);
            target.ResetHealth(); Assert.That(target.Health, Is.EqualTo(100)); Assert.That(go.GetComponent<Collider>().enabled, Is.True);
        }
    }
}
