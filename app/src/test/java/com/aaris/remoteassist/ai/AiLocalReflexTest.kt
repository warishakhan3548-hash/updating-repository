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

class AiLocalReflexTest {
    private val width = 120
    private val height = 240
    private val profile = CaptureProfile(width, height, width, height, 8, 1_000_000, CaptureTier.BALANCED)
    private val ui = AiUiSnapshot("game.app", JSONArray(), emptyList(), false, false, 7, emptyList())

    private fun frame(value: Int, at: Long) = AiRawFrame(
        ByteArray(width * height * 3 / 2) { value.toByte() },
        width,
        height,
        0,
        at
    )

    @Test fun reflexRequiresDepartureBeforeReappearanceAndThenMatchesOnce() = runBlocking {
        var clock = 1_000L
        val reference = AiVisualFingerprint.sample(frame(60, clock).nv21, width, height)
        val frames = ArrayDeque<AiRawFrame>().apply {
            add(frame(170, clock))
            add(frame(60, clock))
        }
        val template = AiLocalReflex(
            id = "dice-ready",
            packageName = "game.app",
            windowId = 7,
            displayWidthPx = width,
            displayHeightPx = height,
            rotation = 0,
            x = 0.5,
            y = 0.5,
            targetId = null,
            referenceFingerprint = reference,
            createdAtMs = clock,
            expiresAtMs = clock + 60_000
        )
        val watcher = AiLocalReflexWatcher(
            ownPackage = "aaris",
            freshFrame = { frames.removeFirst() },
            display = { profile },
            uiSnapshot = { ui },
            now = { clock },
            pause = { clock += it }
        )

        val result = watcher.awaitMatch(template, 2_000)

        assertTrue(result.matched)
        assertEquals("MATCHED_AFTER_DEPARTURE", result.reason)
        assertTrue(watcher.dispatchGuardMatches(template))
    }

    @Test fun unchangedReferenceNeverImmediatelyDoubleTaps() = runBlocking {
        var clock = 1_000L
        val baseline = frame(60, clock)
        val reference = AiVisualFingerprint.sample(baseline.nv21, width, height)
        val template = AiLocalReflex(
            "same-screen", "game.app", 7, width, height, 0,
            0.5, 0.5, null, reference, clock, clock + 60_000
        )
        val watcher = AiLocalReflexWatcher(
            ownPackage = "aaris",
            freshFrame = { frame(60, clock) },
            display = { profile },
            uiSnapshot = { ui },
            now = { clock },
            pause = { clock += it }
        )

        val result = watcher.awaitMatch(template, 500)

        assertFalse(result.matched)
        assertEquals("REFERENCE_NEVER_DEPARTED", result.reason)
    }

    @Test fun sensitiveOrDifferentWindowCannotDispatchRememberedTap() {
        var current = ui
        var clock = 1_000L
        val reference = AiVisualFingerprint.sample(frame(60, clock).nv21, width, height)
        val template = AiLocalReflex("safe", "game.app", 7, width, height, 0, 0.5, 0.5, null, reference, clock, clock + 60_000)
        val watcher = AiLocalReflexWatcher(
            ownPackage = "aaris",
            freshFrame = { frame(60, clock) },
            display = { profile },
            uiSnapshot = { current },
            now = { clock }
        )

        assertTrue(watcher.dispatchGuardMatches(template))
        current = current.copy(windowId = 8)
        assertFalse(watcher.dispatchGuardMatches(template))
        current = ui.copy(sensitiveFocus = true)
        assertFalse(watcher.dispatchGuardMatches(template))
    }
}
