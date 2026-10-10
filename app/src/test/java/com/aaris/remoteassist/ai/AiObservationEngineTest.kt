package com.aaris.remoteassist.ai

import android.graphics.Rect
import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.FrameImageEncoder
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
class AiObservationEngineTest {
    private var clock = 1000L
    private var pixels = ByteArray(120 * 240 * 3 / 2) { 80 }
    private val icon = AiUiNode("chatgpt", "Icon", "ChatGPT", 84, 168, 108, 216, true, false, false, true)
    private var ui: AiUiSnapshot? = AiUiSnapshot("launcher", JSONArray(), emptyList(), false, false, 3, listOf(icon))
    private var profile = CaptureProfile(120, 240, 120, 240, 8, 1_000_000, CaptureTier.BALANCED)
    private var onFrame: () -> Unit = {}
    private val engine = AiObservationEngine("aaris", { profile }, { ui }, {
        onFrame(); AiRawFrame(pixels.clone(), 120, 240, 0, clock)
    }, { clock }, { clock += it }, { frame, _, _, _, _, _ ->
        // JVM YuvImage does not implement JPEG encoding. All pixels, target
        // validation, event races and dispatch checks still use production code.
        FrameImageEncoder.Encoded(byteArrayOf(1), frame.width, frame.height)
    })
    private fun action(observed: JSONObject, name: String = "tap") = JSONObject()
        .put("observationId", observed.getString("observationId")).put("screenVersion", observed.getLong("screenVersion"))
        .put("action", name).put("x", 0.8).put("y", 0.8).put("toX", 0.8).put("toY", 0.35).put("text", "hello")
    private fun animateOtherRegion() {
        pixels = pixels.clone().apply { for (y in 0 until 55) for (x in 0 until 60) this[y * 120 + x] = 125 }
        engine.changed()
    }

    @Test fun continuouslyUpdatingChatStillIssuesUsableHomeAndTapTickets() = runBlocking {
        onFrame = { engine.changed() }
        val observed = engine.observe()
        assertFalse(observed.has("error")); assertFalse(observed.getBoolean("settled"))
        animateOtherRegion()
        val tap = engine.validate(action(observed))
        assertNull(tap.error); assertTrue(tap.stillValid())
        engine.changed() // Own STOP overlay may emit this while moving out of the way.
        assertTrue(tap.stillValid())
        ui = ui!!.copy(packageName = "chat.app", windowId = 4)
        val home = engine.validate(action(observed, "home"))
        assertNull(home.error); assertTrue(home.stillValid())
        engine.invalidate() // Stop/disconnect must still cancel already-validated commands.
        assertFalse(home.stillValid()); assertFalse(tap.stillValid())
    }
    @Test fun swipeAndLongPressAllowAnimationAwayFromTheirTargets() = runBlocking {
        val observed = engine.observe(); animateOtherRegion()
        assertNull(engine.validate(action(observed, "swipe")).error)
        assertNull(engine.validate(action(observed, "long_press")).error)
    }
    @Test fun desktopPagePinchAndSwipeAllowSmallReflowButRejectMajorSceneChange() = runBlocking {
        val observed = engine.observe()
        // A page's text nodes can change while it remains the same screen.
        ui = ui!!.copy(nodes = listOf(icon.copy(text = "India article updated")))
        pixels = pixels.clone().apply {
            for (y in 110 until 144) for (x in 82 until 112) this[y * 120 + x] = 120
        }
        val pinch = action(observed, "two_finger")
            .put("x", 0.35).put("y", 0.55).put("toX", 0.20).put("toY", 0.40)
            .put("secondX", 0.65).put("secondY", 0.55)
            .put("secondToX", 0.80).put("secondToY", 0.72)
        assertNull(engine.validate(pinch).error)
        assertNull(engine.validate(action(observed, "swipe")).error)
        pixels.fill(170.toByte())
        assertEquals("TARGET_CHANGED", engine.validate(pinch).error)
    }
    @Test fun onlyScreenshotLeavesDeviceWhileInternalTargetGuardRemains() = runBlocking {
        val observed = engine.observe()
        assertEquals(0, observed.getJSONArray("uiHints").length())
        assertTrue(observed.getJSONObject("image").getString("data").isNotEmpty())
        val validated = engine.validate(action(observed))
        assertNull(validated.error)
    }
    @Test fun changingPixelColorsAndButtonTextDoNotBlockStationaryTap() = runBlocking {
        val observed = engine.observe()
        pixels = pixels.clone().apply {
            for (y in 175 until 210) for (x in 85 until 107) this[y * 120 + x] = 180.toByte()
        }
        ui = ui!!.copy(nodes = listOf(icon.copy(text = "Animated countdown 11")))
        val accepted = engine.validate(action(observed))
        assertNull(accepted.error)
        assertTrue(accepted.stillValid())
        // A different control really taking the coordinate is still refused.
        ui = ui!!.copy(nodes = listOf(icon.copy(id = "replacement-button", text = "Other")))
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
        assertFalse(accepted.stillValid())
    }

    @Test fun changingOtherTextNeverAddsPreTapScreenCapture() = runBlocking {
        var frameReads = 0
        onFrame = { frameReads++ }
        val observed = engine.observe()
        assertEquals(1, frameReads)
        ui = ui!!.copy(nodes = listOf(icon.copy(text = "Updating...")))
        animateOtherRegion()
        assertNull(engine.validate(action(observed)).error)
        // The normal post-action observe remains the only new screenshot.
        assertEquals(1, frameReads)
    }

    @Test fun disabledOrMovedTapTargetIsStillRejected() = runBlocking {
        val observed = engine.observe()
        ui = ui!!.copy(nodes = listOf(icon.copy(enabled = false)))
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
        ui = ui!!.copy(nodes = listOf(icon.copy(left = 4, right = 28)))
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
        ui = ui!!.copy(nodes = listOf(icon), windowId = 99)
        assertEquals("FOREGROUND_CHANGED", engine.validate(action(observed)).error)
    }

    @Test fun lowSemanticDynamicCanvasToleratesLocalAnimationButKeepsSceneAndWindowGuards() = runBlocking {
        ui = AiUiSnapshot("game.app", JSONArray(), emptyList(), false, false, 9, emptyList())
        val observed = engine.observe()
        assertEquals("dynamic_canvas", observed.getString("interactionMode"))

        pixels = pixels.clone().apply {
            for (y in 175 until 210) for (x in 85 until 107) this[y * 120 + x] = 170.toByte()
        }
        val validation = engine.validate(action(observed))
        assertNull(validation.error)
        assertTrue(validation.stillValid())

        ui = ui!!.copy(windowId = 10)
        assertFalse(validation.stillValid())
    }

    @Test fun dynamicCanvasRejectsMajorSameWindowSceneTransition() = runBlocking {
        ui = AiUiSnapshot("game.app", JSONArray(), emptyList(), false, false, 9, emptyList())
        val observed = engine.observe()
        pixels = ByteArray(120 * 240 * 3 / 2) { 170.toByte() }

        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
    }
    @Test fun consumedExpiredRotatedLockedAndSensitiveTargetsStayBlocked() = runBlocking {
        val observed = engine.observe(); val args = action(observed)
        profile = profile.copy(displayWidthPx = 240, displayHeightPx = 120)
        assertEquals("CAPTURE_GEOMETRY_CHANGED", engine.validate(args).error)
        profile = profile.copy(displayWidthPx = 120, displayHeightPx = 240)
        ui = ui!!.copy(sensitiveFocus = true)
        assertEquals("LOCAL_ONLY_SCREEN", engine.validate(args).error)
        assertNull(engine.validate(action(observed, "back")).error)
        ui = null
        assertEquals("DEVICE_LOCKED_OR_ACCESSIBILITY_OFF", engine.validate(args).error)
        clock += 90_001
        assertEquals("OBSERVATION_EXPIRED_OR_USED", engine.validate(args).error)
        engine.ledger.consume()
        assertEquals("OBSERVATION_EXPIRED_OR_USED", engine.validate(args).error)
    }
    @Test fun typingBindsFocusedFieldAndSelectionAndDispatchDeadline() = runBlocking {
        ui = ui!!.copy(nodes = listOf(icon.copy(editable = true, focused = true, selectionStart = 0, selectionEnd = 0)))
        val observed = engine.observe(); val args = action(observed, "type")
        val valid = engine.validate(args); assertNull(valid.error)
        ui = ui!!.copy(nodes = listOf(ui!!.nodes[0].copy(selectionStart = 1, selectionEnd = 1)))
        assertFalse(valid.stillValid()); assertEquals("TARGET_CHANGED", engine.validate(args).error)
        ui = ui!!.copy(nodes = listOf(ui!!.nodes[0].copy(selectionStart = 0, selectionEnd = 0)))
        val next = engine.validate(args); clock += 501
        assertFalse(next.stillValid())
    }
    @Test fun quietScreensAvoidFixedDelayAndRecentChangesWaitOnlyForQuiescence() = runBlocking {
        val quietStart = clock
        val first = engine.observe()
        assertFalse(first.has("error"))
        assertEquals(quietStart, clock)

        engine.invalidate()
        val changedAt = clock
        val second = engine.observe()
        assertFalse(second.has("error"))
        assertEquals(100L, clock - changedAt)
    }

    @Test fun ordinaryTapKeepsTheExactVisionCoordinateInsideClickableControl() = runBlocking {
        val observed = engine.observe()
        val args = action(observed).put("x", 0.72).put("y", 0.72)
        val validation = engine.validate(args)
        assertNull(validation.error)
        assertEquals(0.72, args.getDouble("x"), 0.0001)
        assertEquals(0.72, args.getDouble("y"), 0.0001)
        assertTrue(validation.stillValid())
    }

    @Test fun settledBroadClickableGameSurfaceKeepsVisionTapCoordinate() = runBlocking {
        val gameSurface = AiUiNode(
            "game-surface", "SurfaceView", "",
            0, 0, 120, 240,
            true, false, false, true
        )
        ui = AiUiSnapshot(
            "game.app",
            JSONArray(),
            emptyList(),
            false,
            false,
            9,
            listOf(gameSurface)
        )

        val observed = engine.observe()
        assertEquals("dynamic_canvas", observed.getString("interactionMode"))

        val args = action(observed)
            .put("x", 0.23)
            .put("y", 0.31)
        val validation = engine.validate(args)

        assertNull(validation.error)
        assertEquals(0.23, args.getDouble("x"), 0.0001)
        assertEquals(0.31, args.getDouble("y"), 0.0001)
        assertTrue(validation.stillValid())
    }

    @Test fun broadClickableContainerNeverRecentersCoordinateTap() = runBlocking {
        val root = AiUiNode(
            "root", "View", "",
            0, 0, 120, 240,
            true, false, false, true
        )
        val labels = listOf(
            AiUiNode("", "TextView", "A", 0, 0, 20, 20, false, false, false, true),
            AiUiNode("", "TextView", "B", 25, 0, 45, 20, false, false, false, true),
            AiUiNode("", "TextView", "C", 50, 0, 70, 20, false, false, false, true),
            AiUiNode("", "TextView", "D", 75, 0, 95, 20, false, false, false, true)
        )
        ui = AiUiSnapshot(
            "custom.app",
            JSONArray(),
            emptyList(),
            false,
            false,
            11,
            listOf(root) + labels
        )

        val observed = engine.observe()
        assertEquals("interactive", observed.getString("interactionMode"))

        val args = action(observed)
            .put("x", 0.26)
            .put("y", 0.72)
        val validation = engine.validate(args)

        assertNull(validation.error)
        assertEquals(0.26, args.getDouble("x"), 0.0001)
        assertEquals(0.72, args.getDouble("y"), 0.0001)
    }

    @Test fun privacyContextChangingDuringCaptureNeverReturnsUnmaskedImage() = runBlocking {
        onFrame = { ui = ui!!.copy(masks = listOf(Rect(0, 0, (++clock % 100).toInt(), 120))) }
        val observed = engine.observe()
        assertEquals("SCREEN_CHANGING", observed.getString("error")); assertFalse(observed.has("image"))
    }
}
