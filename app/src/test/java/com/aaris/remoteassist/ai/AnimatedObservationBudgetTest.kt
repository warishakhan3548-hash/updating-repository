package com.aaris.remoteassist.ai

import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.FrameImageEncoder
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AnimatedObservationBudgetTest {
    @Test
    fun continuouslyChangingScreenStopsWaitingAt220ms() = runBlocking {
        var clock = 1_000L
        val pixels = ByteArray(120 * 240 * 3 / 2) { 80 }
        val profile = CaptureProfile(120, 240, 120, 240, 8, 1_000_000, CaptureTier.BALANCED)
        val ui = AiUiSnapshot(
            packageName = "chat.app",
            hints = JSONArray(),
            masks = emptyList(),
            sensitiveFocus = false,
            truncated = false,
            windowId = 3
        )
        lateinit var engine: AiObservationEngine
        engine = AiObservationEngine(
            ownPackage = "aaris",
            display = { profile },
            uiSnapshot = { ui },
            freshFrame = { AiRawFrame(pixels.clone(), 120, 240, 0, clock) },
            now = { clock },
            pause = { delayMs ->
                clock += delayMs
                // Model a chat/animation that emits another Accessibility event
                // during every settle poll.
                engine.changed()
            },
            encodeFrame = { frame, _, _, _, _, _ ->
                FrameImageEncoder.Encoded(byteArrayOf(1), frame.width, frame.height)
            }
        )

        engine.changed()
        val startedAt = clock
        val observed = engine.observe()

        assertFalse(observed.has("error"))
        assertEquals(220L, clock - startedAt)
    }
}
