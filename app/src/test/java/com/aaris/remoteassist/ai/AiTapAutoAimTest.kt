package com.aaris.remoteassist.ai

import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.FrameImageEncoder
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun coordinateTapRemainsExactWithoutTargetId() = runBlocking {
        val observed = engine.observe()
        val args = tap(observed, 0.69, 0.80)

        val validation = engine.validate(args)

        assertNull(validation.error)
        assertEquals(0.69, args.getDouble("x"), 0.0001)
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
    @Test
    fun browserCoordinatesRemainExactAndLocalResumeRequiresMatchingPixelsAndTargets() = runBlocking {
        val observed = engine.observe()
        val args = tap(observed, 0.72, 0.81)
        ui = ui.copy(windowId = 99)
        assertEquals("FOREGROUND_CHANGED", engine.validate(args, exactCoordinates = true).error)
        assertNull(engine.validate(args, exactCoordinates = true, allowWindowResume = true).error)
        assertEquals(0.72, args.getDouble("x"), 0.0001)
        ui = ui.copy(packageName = "chat")
        assertEquals("FOREGROUND_CHANGED", engine.validate(args, exactCoordinates = true, allowWindowResume = true).error)
    }

    @Test
    fun cloudBrowserTapResumesTheHeldTargetAfterTheOwnerReadsChatGpt() = runBlocking {
        val observed = engine.observe()
        val target = ui
        val args = tap(observed, 0.72, 0.81)
        ui = ui.copy(packageName = "com.openai.chatgpt", windowId = 21)
        engine.changed()
        assertEquals("FOREGROUND_CHANGED", engine.validate(args, exactCoordinates = true).error)
        assertTrue(BrowserAgentCommand.requiresTargetResume("tap", ui.packageName))

        ui = target.copy(windowId = 22)
        val resumed = engine.validate(args, exactCoordinates = true, allowWindowResume = true)
        assertNull(resumed.error)
        assertEquals(0.72, args.getDouble("x"), 0.0001)
        assertTrue(resumed.stillValid())

        ui = ui.copy(packageName = "another.app")
        assertFalse(resumed.stillValid())
        assertFalse(BrowserAgentCommand.requiresTargetResume("tap", ui.packageName))
    }

    @Test
    fun resumingFromAiChatCannotAuthorizeAChangedTargetScene() = runBlocking {
        val observed = engine.observe()
        val args = tap(observed, 0.72, 0.81)
        ui = ui.copy(windowId = 22)
        pixels.fill(150.toByte())
        assertEquals("RESTORED_SCREEN_CHANGED", engine.validate(args, exactCoordinates = true, allowWindowResume = true).error)
        assertFalse(BrowserAgentCommand.requiresTargetResume("home", "com.openai.chatgpt"))
        assertFalse(BrowserAgentCommand.requiresTargetResume("open_app", "com.openai.chatgpt"))
    }

}
