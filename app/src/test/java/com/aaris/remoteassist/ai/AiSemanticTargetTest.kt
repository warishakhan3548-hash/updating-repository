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
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class AiSemanticTargetTest {
    private var clock = 1_000L
    private val pixels = ByteArray(120 * 240 * 3 / 2) { 80 }
    private val profile =
        CaptureProfile(120, 240, 120, 240, 8, 1_000_000, CaptureTier.BALANCED)
    private val primary = AiUiNode(
        id = "launcher:id/open",
        role = "android.widget.Button",
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
    private var ui = snapshot(listOf(primary))

    private val engine = AiObservationEngine(
        ownPackage = "aaris",
        display = { profile },
        uiSnapshot = { ui },
        freshFrame = { AiRawFrame(pixels.clone(), 120, 240, 0, clock) },
        now = { clock },
        pause = { clock += it },
        encodeFrame = { frame, _, _, _, _, _, _ ->
            FrameImageEncoder.Encoded(byteArrayOf(1), frame.width, frame.height)
        }
    )

    private fun snapshot(nodes: List<AiUiNode>): AiUiSnapshot {
        val hints = JSONArray()
        nodes.forEach { node ->
            hints.put(
                JSONObject()
                    .put("text", node.text)
                    .put("role", node.role.substringAfterLast('.'))
                    .put("bounds", JSONArray(listOf(node.left, node.top, node.right, node.bottom)))
                    .put("clickable", node.clickable)
                    .put("editable", node.editable)
            )
        }
        return AiUiSnapshot(
            packageName = "launcher",
            hints = hints,
            masks = emptyList(),
            sensitiveFocus = false,
            truncated = false,
            windowId = 7,
            nodes = nodes
        )
    }

    private fun tap(observed: JSONObject, targetId: String) = JSONObject()
        .put("observationId", observed.getString("observationId"))
        .put("screenVersion", observed.getLong("screenVersion"))
        .put("action", "tap")
        // Coordinates remain present for backward compatibility with older phones.
        .put("x", 0.10)
        .put("y", 0.10)
        .put("targetId", targetId)

    @Test
    fun uniqueClickableIdIsPublishedAndOverridesImpreciseVisionCoordinates() = runBlocking {
        val observed = engine.observe()
        val hint = observed.getJSONArray("uiHints").getJSONObject(0)
        assertEquals("launcher:id/open", hint.getString("targetId"))
        assertEquals(true, hint.getBoolean("enabled"))
        assertEquals(false, hint.getBoolean("focused"))

        val args = tap(observed, "launcher:id/open")
        val validation = engine.validate(args)

        assertNull(validation.error)
        assertEquals(0.80, args.getDouble("x"), 0.0001)
        assertEquals(0.80, args.getDouble("y"), 0.0001)
        assertEquals(true, validation.stillValid())
    }

    @Test
    fun uniqueEditableIdCanBeFocusedPreciselyEvenWhenAndroidSaysNotClickable() = runBlocking {
        val field = AiUiNode(
            id = "form:id/name",
            role = "android.widget.EditText",
            text = "",
            left = 12,
            top = 72,
            right = 108,
            bottom = 120,
            clickable = false,
            editable = true,
            focused = false,
            enabled = true
        )
        ui = snapshot(listOf(field))

        val observed = engine.observe()
        val hint = observed.getJSONArray("uiHints").getJSONObject(0)
        assertEquals("form:id/name", hint.getString("targetId"))
        assertEquals(true, hint.getBoolean("enabled"))
        assertEquals(false, hint.getBoolean("focused"))

        val args = tap(observed, "form:id/name")
        val validation = engine.validate(args)

        assertNull(validation.error)
        assertEquals(0.50, args.getDouble("x"), 0.0001)
        assertEquals(0.40, args.getDouble("y"), 0.0001)
        assertEquals(true, validation.stillValid())
    }

    @Test
    fun repeatedResourceIdIsNeverPublishedOrAcceptedAsSemanticTarget() = runBlocking {
        ui = snapshot(
            listOf(
                primary,
                primary.copy(left = 12, top = 24, right = 36, bottom = 72, text = "Other")
            )
        )
        val observed = engine.observe()
        val hints = observed.getJSONArray("uiHints")
        assertFalse(hints.getJSONObject(0).has("targetId"))
        assertFalse(hints.getJSONObject(1).has("targetId"))

        val validation = engine.validate(tap(observed, "launcher:id/open"))
        assertEquals("TARGET_CHANGED", validation.error)
    }
}
