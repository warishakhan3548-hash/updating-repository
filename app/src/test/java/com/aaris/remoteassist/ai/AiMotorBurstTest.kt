package com.aaris.remoteassist.ai

import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class AiMotorBurstTest {
    private val width = 120
    private val height = 240
    private val profile = CaptureProfile(width, height, width, height, 8, 1_000_000, CaptureTier.BALANCED)
    private var ui = AiUiSnapshot("fast.app", JSONArray(), emptyList(), false, false, 7, emptyList())

    private fun frame(value: Int = 80): AiRawFrame =
        AiRawFrame(ByteArray(width * height * 3 / 2) { value.toByte() }, width, height, 0, 1_000L)

    @Test fun policyAcceptsShortTouchBurstAndRejectsLongOrNonMotorPrograms() {
        val good = JSONArray()
            .put(JSONObject().put("action", "tap").put("x", 0.4).put("y", 0.6).put("afterMs", 80))
            .put(JSONObject().put("action", "drag")
                .put("points", JSONArray()
                    .put(JSONObject().put("x", 0.4).put("y", 0.6))
                    .put(JSONObject().put("x", 0.55).put("y", 0.5)))
                .put("durationMs", 240))
        assertEquals(2, AiMotorBurstPolicy.parseSteps(good).size)

        val forbidden = JSONArray().put(
            JSONObject().put("action", "type").put("text", "hello")
        )
        assertThrows(IllegalArgumentException::class.java) {
            AiMotorBurstPolicy.parseSteps(forbidden)
        }

        val tooLong = JSONArray()
        repeat(4) {
            tooLong.put(
                JSONObject().put("action", "long_press")
                    .put("x", 0.5).put("y", 0.5)
                    .put("durationMs", 700)
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            AiMotorBurstPolicy.parseSteps(tooLong)
        }
    }

    @Test fun monitorStopsBurstWhenWindowChanges() = runBlocking {
        val guard = AiMotorBurstGuard("fast.app", 7, width, height, 0)
        val monitor = AiMotorBurstMonitor(
            ownPackage = "aaris",
            freshFrame = { frame() },
            display = { profile },
            uiSnapshot = { ui }
        )
        assertTrue(monitor.environmentMatches(guard))
        ui = ui.copy(windowId = 8)
        assertFalse(monitor.environmentMatches(guard))
    }

    @Test fun checkpointAllowsSmallMotionAndRejectsLargeSceneTransition() = runBlocking {
        val guard = AiMotorBurstGuard("fast.app", 7, width, height, 0)
        val baseline = AiVisualFingerprint.sample(frame().nv21, width, height)

        var current = frame()
        val monitor = AiMotorBurstMonitor(
            ownPackage = "aaris",
            freshFrame = { current },
            display = { profile },
            uiSnapshot = { ui },
            pause = {}
        )

        val small = monitor.checkpoint(guard, baseline, 0)
        assertTrue(small.safe)

        current = frame(190)
        val large = monitor.checkpoint(guard, baseline, 0)
        assertFalse(large.safe)
        assertEquals("BURST_SCENE_CHANGED", large.reason)
    }
}
