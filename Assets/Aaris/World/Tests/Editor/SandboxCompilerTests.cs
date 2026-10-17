using System.Linq;
using NUnit.Framework;
using UnityEngine;
using Aaris.World.Editor;

namespace Aaris.World.Tests
{
    public sealed class SandboxCompilerTests
    {
        [Test]
        public void CompiledSandboxWiresOnlyBoundedNativeBodiesAndGameplayReferences()
        {
            PhysicsSandboxCompiler.Compile(); var spec = PhysicsSandboxCompiler.Read();
            var session = Object.FindFirstObjectByType<SandboxSession>();
            Assert.That(session, Is.Not.Null); Assert.That(session.pawn.input, Is.SameAs(session.input));
            Assert.That(session.world, Is.Not.Null);
            Assert.That(session.world.grid.sizeX, Is.GreaterThan(0));
            Assert.That(session.world.landmarks.Length, Is.GreaterThan(0));
            Assert.That(session.pawn.cameraRig, Is.SameAs(session.cameraRig)); Assert.That(session.weapon.muzzle, Is.Not.Null);
            Assert.That(session.pawn.Body.mass, Is.EqualTo(spec.movement.mass).Within(0.001));
            Assert.That(session.pawn.Body.collisionDetectionMode, Is.EqualTo(CollisionDetectionMode.ContinuousDynamic));
            Assert.That(session.props.Length, Is.EqualTo(spec.props.Length)); Assert.That(session.targets.Length, Is.EqualTo(spec.targets.Length));
            Assert.That(Object.FindObjectsByType<Rigidbody>(FindObjectsSortMode.None).Length, Is.EqualTo(1 + spec.props.Length));
            Assert.That(session.props.All(p => p.GetComponent<BoxCollider>() != null && p.GetComponent<MeshCollider>() == null), Is.True);
            Assert.That(Object.FindObjectsByType<WorldObjectIdentity>(FindObjectsSortMode.None).All(o => o.GetComponent<Rigidbody>() == null), Is.True);
            Assert.That(session.weapon.cameraRig, Is.SameAs(session.cameraRig)); Assert.That(session.propStarts.Length, Is.EqualTo(session.props.Length));
        }
    }
}
