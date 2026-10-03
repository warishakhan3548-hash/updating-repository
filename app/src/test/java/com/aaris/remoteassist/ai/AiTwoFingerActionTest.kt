package com.aaris.remoteassist.ai

import com.aaris.remoteassist.control.TwoFingerCommand
import com.aaris.remoteassist.session.LiveLease
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class AiTwoFingerActionTest {
    private val lease = LiveLease(
        sessionId = "session",
        leaseSecret = 123L,
        displayGeneration = 7
    )

    @Test
    fun translatorMapsTwoPointersOntoExistingAccessibilityExecutor() {
        val args = JSONObject()
            .put("action", "two_finger")
            .put("durationMs", 450)
            .put("firstX", 0.40).put("firstY", 0.50)
            .put("firstToX", 0.25).put("firstToY", 0.50)
            .put("secondX", 0.60).put("secondY", 0.50)
            .put("secondToX", 0.75).put("secondToY", 0.50)

        val command = AiActionTranslator.translate(
            args = args,
            lease = lease,
            sequence = 11L,
            width = 1000,
            height = 2000
        ) as TwoFingerCommand

        assertEquals(450L, command.durationMs)
        assertEquals(400f, command.firstFromXPx, 0.01f)
        assertEquals(250f, command.firstToXPx, 0.01f)
        assertEquals(600f, command.secondFromXPx, 0.01f)
        assertEquals(750f, command.secondToXPx, 0.01f)
    }

    @Test
    fun independentPointerScopesDoNotInventUnsafeBridgeBetweenFingers() {
        val scope = AiActionScope.fromPaths(
            listOf(
                listOf(0.20 to 0.40, 0.20 to 0.70),
                listOf(0.80 to 0.40, 0.80 to 0.70)
            )
        )

        assertTrue(scope.contains(0.20, 0.55))
        assertTrue(scope.contains(0.80, 0.55))
        assertFalse(scope.contains(0.50, 0.55))
    }
}
