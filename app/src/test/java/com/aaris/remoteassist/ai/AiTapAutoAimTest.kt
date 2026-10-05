package com.aaris.remoteassist.ai

import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.FrameImageEncoder
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class AiTapAutoAimTest {
    private var clock = 1_000L
    private val pixels = ByteArray(120 * 240 * 3 / 2) { 80 }
    private val profile =
        CaptureProfile(120, 240, 120, 240, 8, 1_000_000, CaptureTier.BALANCED)
    private val primary =
        AiUiNode(
            id = "primary",
            role = "Button",
            text = "Open",
            left = 84,
            top = 168,
            right = 108,
            bottom = 216,
            clickable = true,
            editable = false,
            focused = false,
            enabled = true
        )
    private var ui =
        AiUiSnapshot(
            packageName = "launcher",
            hints = JSONArray(),
            masks = emptyList(),
            sensitiveFocus = false,
            truncated = false,
            windowId = 7,
            nodes = listOf(primary)
        )

    private val engine = AiObservationEngine(
        ownPackage = "aaris",
        display = { profile },
        uiSnapshot = { ui },
        freshFrame = { AiRawFrame(pixels.clone(), 120, 240, 0, clock) },
        now = { clock },
        pause = { clock += it },
        encodeFrame = { frame, _, _, _, _, _ ->
            FrameImageEncoder.Encoded(byteArrayOf(1), frame.width, frame.height)
        }
    )

    private fun tap(observed: JSONObject, x: Double, y: Double) =
        JSONObject()
            .put("observationId", observed.getString("observationId"))
            .put("screenVersion", observed.getLong("screenVersion"))
            .put("action", "tap")
            .put("x", x)
            .put("y", y)

    @Test
    fun isolatedNearMissSnapsToClickableCenter() = runBlocking {
        val observed = engine.observe()
        val args = tap(observed, 0.69, 0.80)

        val validation = engine.validate(args)

        assertNull(validation.error)
        assertEquals(0.80, args.getDouble("x"), 0.0001)
        assertEquals(0.80, args.getDouble("y"), 0.0001)
        assertTrue(validation.stillValid())
    }

    @Test
    fun adjacentTargetsDisableNearMissGuessing() = runBlocking {
        val neighbor = primary.copy(
            id = "neighbor",
            text = "More",
            left = 72,
            right = 82
        )
        ui = ui.copy(nodes = listOf(primary, neighbor))
        val observed = engine.observe()
        val args = tap(observed, 0.69, 0.80)

        val validation = engine.validate(args)

        assertNull(validation.error)
        assertEquals(0.69, args.getDouble("x"), 0.0001)
        assertEquals(0.80, args.getDouble("y"), 0.0001)
        assertTrue(validation.stillValid())
    }
}
