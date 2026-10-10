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

    @Test fun stableSearchButtonAcceptsTapWhileAdjacentAndMostOfVideoChanges() = runBlocking {
        val search = icon.copy(id = "youtube:id/search", text = "Search", left = 96, right = 108, top = 12, bottom = 20)
        ui = ui!!.copy(packageName = "youtube", nodes = listOf(search))
        onFrame = { engine.changed() }
        val observed = engine.observe()
        assertFalse(observed.getBoolean("settled"))
        // The old padded point guard extended BELOW this tiny toolbar button.
        // Every video pixel changes while the actual search button stays still.
        pixels = pixels.clone().apply {
            for (y in 20 until 240) for (x in 0 until 120) this[y * 120 + x] = 175.toByte()
        }
        val validation = engine.validate(action(observed).put("x", 0.85).put("y", 16.0 / 240))
        assertNull(validation.error)
        assertTrue(validation.stillValid())
    }

    @Test fun stableBoundedControlIgnoresTransientOverlayPixels() = runBlocking {
        val search = icon.copy(id = "browser:id/search", text = "Search", left = 88, right = 112, top = 178, bottom = 206)
        ui = ui!!.copy(packageName = "browser", nodes = listOf(search))
        val observed = engine.observe()

        // Model a progress/accessibility HUD overlapping a substantial part of
        // the button between screenshot selection and dispatch. The live bounded
        // control itself is unchanged and still enabled.
        pixels = pixels.clone().apply {
            for (y in 178 until 206) for (x in 88 until 100) this[y * 120 + x] = 175.toByte()
        }
        engine.changed()

        val args = action(observed).put("x", 0.83).put("y", 0.80)
        val validation = engine.validate(args)
        assertNull(validation.error)
        assertTrue(validation.stillValid())

        // A real control replacement must still stop the touch.
        ui = ui!!.copy(nodes = listOf(search.copy(text = "Delete")))
        assertFalse(validation.stillValid())
        assertEquals("TARGET_CHANGED", engine.validate(args).error)
    }

    @Test fun stableVisionTargetAllowsLargeVideoMotionWithoutAccessibilityNodes() = runBlocking {
        ui = AiUiSnapshot("video.canvas", JSONArray(), emptyList(), false, false, 8, emptyList())
        val observed = engine.observe()
        assertEquals("dynamic_canvas", observed.getString("interactionMode"))
        pixels = pixels.clone().apply {
            for (y in 0 until 240) for (x in 0 until 120) {
                // Preserve the screenshot-selected search target and its
                // complete padded guard; animate almost everything else.
                if (x !in 90..104 || y !in 183..201) this[y * 120 + x] = 175.toByte()
            }
        }
        val validation = engine.validate(action(observed))
        assertNull(validation.error)
        assertTrue(validation.stillValid())
        pixels.fill(175.toByte())
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
    }

    @Test fun changingDecorativeLabelDoesNotBecomeTheClickTarget() = runBlocking {
        val badge = icon.copy(id = "badge", role = "TextView", text = "1", left = 92, top = 188,
            right = 100, bottom = 196, clickable = false, supportsClick = false)
        ui = ui!!.copy(nodes = listOf(icon, badge))
        val observed = engine.observe()
        ui = ui!!.copy(nodes = listOf(icon, badge.copy(text = "2")))
        assertNull(engine.validate(action(observed)).error)
        ui = ui!!.copy(nodes = listOf(icon.copy(enabled = false), badge))
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
    }

    @Test fun unrelatedSiblingInsertionKeepsStationaryControlUsable() = runBlocking {
        ui = ui!!.copy(nodes = listOf(icon.copy(treePath = "0/1")))
        val observed = engine.observe()
        ui = ui!!.copy(nodes = listOf(icon.copy(treePath = "0/2")))
        assertNull(engine.validate(action(observed)).error)
        ui = ui!!.copy(nodes = listOf(icon.copy(treePath = "0/2", left = 82)))
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
    }

    @Test fun typingIgnoresTreePositionButStillBindsActualValueAndSelection() = runBlocking {
        val field = icon.copy(editable = true, focused = true, selectionStart = 0, selectionEnd = 0, treePath = "0/1")
        ui = ui!!.copy(nodes = listOf(field))
        val observed = engine.observe()
        ui = ui!!.copy(nodes = listOf(field.copy(treePath = "0/2")))
        val validation = engine.validate(action(observed, "type"))
        assertNull(validation.error)
        assertTrue(validation.stillValid())
        ui = ui!!.copy(nodes = listOf(field.copy(treePath = "0/2", selectionStart = 1)))
        assertFalse(validation.stillValid())
    }

    @Test fun optionalSemanticClickBindsLiveNodeRatherThanAnimatedPixels() = runBlocking {
        ui = ui!!.copy(nodes = listOf(icon.copy(treePath = "0/0")))
        val observed = engine.observe()
        pixels.fill(175.toByte())
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
        val semantic = engine.validate(action(observed, "semantic_click"))
        assertNull(semantic.error)
        assertNotNull(semantic.semanticTarget)
        assertTrue(semantic.stillValid())
        ui = ui!!.copy(nodes = listOf(icon.copy(treePath = "0/0", text = "Delete")))
        assertFalse(semantic.stillValid())
        assertEquals("TARGET_CHANGED", engine.validate(action(observed, "semantic_click")).error)
    }

    @Test fun semanticUnavailableDoesNotConsumeTicketAndStopStillRevokesValidatedClick() = runBlocking {
        val unavailable = engine.observe()
        assertEquals("SEMANTIC_TARGET_UNAVAILABLE", engine.validate(action(unavailable, "semantic_click")).error)
        assertNull(engine.validate(action(unavailable)).error)
        ui = ui!!.copy(nodes = listOf(icon.copy(treePath = "0/0")))
        val observed = engine.observe()
        val semantic = engine.validate(action(observed, "semantic_click"))
        assertNull(semantic.error)
        engine.invalidate()
        assertFalse(semantic.stillValid())
    }

    @Test fun actualPopupStillReturnsNewWindowGuardInsteadOfClickingThroughIt() = runBlocking {
        val observed = engine.observe()
        ui = ui!!.copy(windowId = 44)
        assertEquals("FOREGROUND_CHANGED", engine.validate(action(observed)).error)
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
    @Test fun actualTargetPixelsOrSemanticsChangingRejectsTap() = runBlocking {
        val observed = engine.observe()
        pixels = pixels.clone().apply { for (y in 175 until 210) for (x in 85 until 107) this[y * 120 + x] = 180.toByte() }
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
        pixels.fill(80)
        val validated = engine.validate(action(observed)); assertNull(validated.error)
        ui = ui!!.copy(nodes = listOf(icon.copy(text = "Delete")))
        assertEquals("TARGET_CHANGED", engine.validate(action(observed)).error)
        assertFalse(validated.stillValid())
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

    @Test fun tapCoordinatesSnapToSmallestEnabledClickableTargetCenter() = runBlocking {
        val observed = engine.observe()
        val args = action(observed).put("x", 0.72).put("y", 0.72)
        val validation = engine.validate(args)
        assertNull(validation.error)
        assertEquals(0.8, args.getDouble("x"), 0.0001)
        assertEquals(0.8, args.getDouble("y"), 0.0001)
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

    @Test fun detailObservationUsesDedicatedFreshFrameLaneOnlyWhenRequested() = runBlocking {
        var normalCaptures = 0
        var detailCaptures = 0
        fun capturedFrame() =
            AiRawFrame(
                pixels.clone(),
                120,
                240,
                0,
                clock
            )

        val routed =
            AiObservationEngine(
                ownPackage = "aaris",
                display = { profile },
                uiSnapshot = { ui },
                freshFrame = {
                    normalCaptures += 1
                    capturedFrame()
                },
                now = { clock },
                pause = { clock += it },
                encodeFrame = { frame, _, _, _, _, _ ->
                    FrameImageEncoder.Encoded(
                        byteArrayOf(1),
                        frame.width,
                        frame.height
                    )
                },
                freshDetailFrame = {
                    detailCaptures += 1
                    capturedFrame()
                }
            )

        assertFalse(routed.observe().has("error"))
        assertEquals(1, normalCaptures)
        assertEquals(0, detailCaptures)

        routed.invalidate()
        assertFalse(routed.observe(detail = true).has("error"))
        assertEquals(1, normalCaptures)
        assertEquals(1, detailCaptures)
    }
}

