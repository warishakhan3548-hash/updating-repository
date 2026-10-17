using NUnit.Framework;
using UnityEngine;
using WorldEditor = Aaris.World.Editor.UnityWorldCompiler;

namespace Aaris.World.Tests
{
    public sealed class AtmosphereIntegrationTests
    {
        [Test]
        public void GeneratedReviewSceneHasOnePlayModeOnlyAtmosphereController()
        {
            WorldEditor.Compile();
            var cycles = Object.FindObjectsByType<AtmosphereCycle>(FindObjectsSortMode.None);
            Assert.That(cycles, Has.Length.EqualTo(1));
            var controller = cycles[0];
            Assert.That(controller.sun, Is.Not.Null);
            Assert.That(controller.sun, Is.SameAs(controller.GetComponent<Light>()));
            Assert.That(controller.sun.type, Is.EqualTo(LightType.Directional));
            Assert.That(controller.cycleSeconds, Is.InRange(120f, 7200f));
            Assert.That(controller.updateIntervalSeconds, Is.InRange(0.05f, 1f));
            Assert.That(Application.isPlaying, Is.False, "EditMode review must keep original still lighting.");
            Assert.That(RenderSettings.fogDensity,
                Is.EqualTo((float)WorldEditor.ReadWorld().visuals.fogDensity).Within(1e-6));
        }
    }
}
