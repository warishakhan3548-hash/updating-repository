using System;
using System.Linq;
using Aaris.World.Editor;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Aaris.World.Tests
{
    public sealed class CharacterPresentationTests
    {
        private GameObject owner;
        private Material[] palette;
        private CharacterPresentation character;
        private const float Height = 1.8f;

        [SetUp]
        public void SetUp()
        {
            var shader = Shader.Find("Universal Render Pipeline/Lit");
            Assert.That(shader, Is.Not.Null);
            palette = Enumerable.Range(0, 5).Select(i => new Material(shader) { name = "CharacterTest" + i }).ToArray();
            owner = new GameObject("Character presentation test owner");
            character = CharacterArtBuilder.Build(owner.transform, Height, palette[0], palette[1], palette[2], palette[3], palette[4]);
        }

        [TearDown]
        public void TearDown()
        {
            if (owner != null) Object.DestroyImmediate(owner);
            if (palette != null) foreach (var material in palette) Object.DestroyImmediate(material);
        }

        [Test]
        public void HumanoidArtHasHumanScaleAndNoPhysicsComponentsOrMaterialClones()
        {
            var renderers = character.GetComponentsInChildren<Renderer>();
            var bounds = renderers[0].bounds;
            foreach (var renderer in renderers) bounds.Encapsulate(renderer.bounds);
            Assert.That(bounds.min.y, Is.GreaterThanOrEqualTo(-0.01f));
            Assert.That(bounds.max.y, Is.InRange(Height * 0.95f, Height * 1.05f));
            Assert.That(character.head.position.y, Is.InRange(Height * 0.85f, Height * 0.90f));
            Assert.That(character.leftThigh.position.x, Is.LessThan(0));
            Assert.That(character.rightThigh.position.x, Is.GreaterThan(0));
            Assert.That(character.GetComponentsInChildren<Collider>(true), Is.Empty);
            Assert.That(character.GetComponentsInChildren<Rigidbody>(true), Is.Empty);
            Assert.That(renderers.Length, Is.LessThanOrEqualTo(48));
            Assert.That(renderers.Select(r => r.sharedMaterial).Distinct().Count(), Is.EqualTo(5));
            Assert.That(renderers.All(r => palette.Contains(r.sharedMaterial)), Is.True);
            Assert.That(character.GetComponentsInChildren<MeshFilter>().Select(m => m.sharedMesh).Distinct().Count(), Is.LessThanOrEqualTo(4));
        }

        [Test]
        public void RifleMuzzleAndHandsRemainCoherentDuringAimSprintAndStrideWithoutMovingPhysicsRoot()
        {
            owner.transform.SetPositionAndRotation(new Vector3(7, 3, -4), Quaternion.Euler(0, 37, 0));
            character.transform.localRotation = Quaternion.Euler(0, 58, 0);
            Vector3 ownerPosition = owner.transform.position;
            Quaternion ownerRotation = owner.transform.rotation;
            Quaternion visualRotation = character.transform.localRotation;
            Vector3 muzzleOffset = character.muzzle.localPosition;
            var barrel = character.rifle.Find("Barrel");
            // A unit Unity cylinder extends from -1 to +1 along local Y.
            Assert.That(Vector3.Distance(barrel.TransformPoint(Vector3.up), character.muzzle.position), Is.LessThan(Height * 0.002f));
            foreach (float pitch in new[] { -30f, 0f, 55f })
            {
                for (int i = 0; i < 12; i++)
                {
                    character.UpdatePose(0.05f, character.transform.forward * 7.5f, true, i % 2 == 0, i % 2 != 0, pitch);
                    Assert.That(character.muzzle.parent, Is.SameAs(character.rifle));
                    Assert.That(character.muzzle.localPosition, Is.EqualTo(muzzleOffset));
                    Assert.That(Vector3.Distance(barrel.TransformPoint(Vector3.up), character.muzzle.position), Is.LessThan(Height * 0.002f));
                    Assert.That(Vector3.Distance(character.leftForearm.TransformPoint(Vector3.down * Height * 0.16f), character.leftGrip.position), Is.LessThan(0.002f));
                    Assert.That(Vector3.Distance(character.rightForearm.TransformPoint(Vector3.down * Height * 0.16f), character.rightGrip.position), Is.LessThan(0.002f));
                }
            }
            Assert.That(owner.transform.position, Is.EqualTo(ownerPosition));
            Assert.That(owner.transform.rotation, Is.EqualTo(ownerRotation));
            Assert.That(character.transform.localPosition, Is.EqualTo(Vector3.zero));
            Assert.That(character.transform.localRotation, Is.EqualTo(visualRotation));
        }

        [Test]
        public void VelocityDrivesBoundedFootStrideAndInvalidPoseInputIsRejected()
        {
            Vector3 rest = character.leftFoot.position;
            for (int i = 0; i < 6; i++) character.UpdatePose(0.05f, Vector3.forward * 4.5f, true, false, false, 0);
            Assert.That(Vector3.Distance(rest, character.leftFoot.position), Is.GreaterThan(0.03f));
            for (int i = 0; i < 12; i++) character.UpdatePose(0.05f, Vector3.zero, true, false, false, 0);
            Vector3 stopped = character.leftFoot.position;
            for (int i = 0; i < 12; i++) character.UpdatePose(0.05f, Vector3.zero, true, false, false, 0);
            Assert.That(Vector3.Distance(stopped, character.leftFoot.position), Is.LessThan(0.001f));
            character.UpdatePose(float.MaxValue, new Vector3(float.MaxValue, 0, float.MaxValue), false, true, true, float.MaxValue);
            Assert.That(character.GetComponentsInChildren<Transform>().All(t => WorldValidator.Finite(t.position.x) && WorldValidator.Finite(t.position.y) && WorldValidator.Finite(t.position.z)), Is.True);
            Assert.Throws<ArgumentException>(() => character.UpdatePose(0.02f, new Vector3(float.NaN, 0, 0), true, false, false, 0));
            Assert.Throws<ArgumentException>(() => character.UpdatePose(float.PositiveInfinity, Vector3.zero, true, false, false, 0));
        }
    }
}
