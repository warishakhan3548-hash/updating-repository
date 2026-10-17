using NUnit.Framework;
using UnityEngine;

namespace Aaris.World.Tests
{
    public sealed class HudLayoutTests
    {
        [TestCase(0, 0, 320, 568, 568)]
        [TestCase(0, 34, 390, 763, 844)]
        [TestCase(59, 21, 734, 351, 393)]
        [TestCase(72, 60, 1296, 640, 800)]
        [TestCase(0, 0, 240, 240, 240)]
        [TestCase(0, 0, 1920, 1080, 1080)]
        public void TacticalPanelsRespectSafeAreaAndNeverCoverActionControls(float x, float y, float width, float height, int screenHeight)
        {
            var safe = new Rect(x, y, width, height);
            SandboxHud.CalculatePanels(safe, screenHeight, out Rect info, out Rect map);
            var guiSafe = new Rect(x, screenHeight - safe.yMax, width, height);
            foreach (var panel in new[] { info, map })
            {
                Assert.That(panel.width, Is.GreaterThan(0));
                Assert.That(panel.height, Is.GreaterThan(0));
                Assert.That(panel.xMin, Is.GreaterThanOrEqualTo(guiSafe.xMin));
                Assert.That(panel.yMin, Is.GreaterThanOrEqualTo(guiSafe.yMin));
                Assert.That(panel.xMax, Is.LessThanOrEqualTo(guiSafe.xMax));
                Assert.That(panel.yMax, Is.LessThanOrEqualTo(guiSafe.yMax));
                foreach (var role in new[] { TouchRole.Move, TouchRole.Fire, TouchRole.Jump, TouchRole.Reload, TouchRole.Aim, TouchRole.Sprint })
                {
                    var control = ControlLayout.Rect(role);
                    var rect = new Rect(x + (float)control.x * width,
                        screenHeight - y - (float)(control.y + control.height) * height,
                        (float)control.width * width, (float)control.height * height);
                    Assert.That(panel.Overlaps(rect), Is.False, "Panel covers " + role);
                }
            }
            Assert.That(info.Overlaps(map), Is.False);
        }
    }
}
