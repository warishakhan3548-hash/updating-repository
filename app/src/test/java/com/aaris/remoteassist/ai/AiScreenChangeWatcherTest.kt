package com.aaris.remoteassist.ai

import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AiScreenChangeWatcherTest {
    private val width = 120
    private val height = 240
    private val profile = CaptureProfile(width, height, width, height, 8, 1_000_000, CaptureTier.BALANCED)
    private var ui = AiUiSnapshot("game.app", JSONArray(), emptyList(), false, false, 7, emptyList())

    private fun frame(mutator: (ByteArray) -> Unit = {}): AiRawFrame {
        val pixels = ByteArray(width * height * 3 / 2) { 80 }
        mutator(pixels)
        return AiRawFrame(pixels, width, height, 0, 1_000L)
    }

    private fun baseline(): AiWaitBaseline {
        val base = frame()
        return AiWaitBaseline(
            packageName = "game.app",
            windowId = 7,
            displayWidthPx = width,
            displayHeightPx = height,
            rotation = 0,
            fingerprint = AiVisualFingerprint.sample(base.nv21, width, height),
            createdAtMs = 1_000L
        )
    }

    @Test fun regionWatchIgnoresOutsideMotionThenTriggersOnInsideChange() = runBlocking {
        var clock = 1_000L
        val frames = ArrayDeque<AiRawFrame>().apply {
            add(frame { pixels ->
                for (y in 0 until 50) for (x in 0 until 30) pixels[y * width + x] = 160.toByte()
            })
            add(frame { pixels ->
                for (y in 145 until 205) for (x in 70 until 105) pixels[y * width + x] = 170.toByte()
            })
        }
        val watcher = AiScreenChangeWatcher(
            ownPackage = "aaris",
            freshFrame = { frames.removeFirst() },
            display = { profile },
            uiSnapshot = { ui },
            now = { clock },
            pause = { clock += it }
        )

        val result = watcher.awaitChange(
            baseline = baseline(),
            waitMs = 2_000,
            minChangeRatio = 0.05,
            region = AiWaitRegion(0.5, 0.5, 0.95, 0.95)
        )

        assertTrue(result.changed)
        assertEquals("REGION_CHANGED", result.reason)
        assertTrue((result.changeRatio ?: 0.0) >= 0.05)
        assertTrue(result.waitedMs >= 125L)
    }

    @Test fun unchangedScreenTimesOutWithoutInventingAChange() = runBlocking {
        var clock = 1_000L
        val watcher = AiScreenChangeWatcher(
            ownPackage = "aaris",
            freshFrame = { frame() },
            display = { profile },
            uiSnapshot = { ui },
            now = { clock },
            pause = { clock += it }
        )

        val result = watcher.awaitChange(baseline(), 500, 0.05)

        assertFalse(result.changed)
        assertEquals("WAIT_TIMEOUT", result.reason)
        assertEquals(500L, result.waitedMs)
    }

    @Test fun foregroundTransitionReturnsImmediatelyWithoutPixelPolling() = runBlocking {
        var clock = 1_000L
        var frameCalls = 0
        ui = ui.copy(packageName = "other.app", windowId = 8)
        val watcher = AiScreenChangeWatcher(
            ownPackage = "aaris",
            freshFrame = { frameCalls++; frame() },
            display = { profile },
            uiSnapshot = { ui },
            now = { clock },
            pause = { clock += it }
        )

        val result = watcher.awaitChange(baseline(), 2_000, 0.05)

        assertTrue(result.changed)
        assertEquals("WINDOW_CHANGED", result.reason)
        assertEquals(0, frameCalls)
    }
}
