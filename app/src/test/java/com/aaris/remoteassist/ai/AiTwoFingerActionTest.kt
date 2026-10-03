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
    fun translatorMapsTwoFingerOntoExistingAtomicGesture() {
        val args = JSONObject()
            .put("action", "two_finger")
            .put("durationMs", 240)
            .put("x", 0.20)
            .put("y", 0.75)
            .put("toX", 0.20)
            .put("toY", 0.75)
            .put("secondX", 0.70)
            .put("secondY", 0.70)
            .put("secondToX", 0.80)
            .put("secondToY", 0.30)

        val command = AiActionTranslator.translate(
            args = args,
            lease = lease,
            sequence = 12L,
            width = 101,
            height = 201
        ) as TwoFingerCommand

        assertEquals("session", command.sessionId)
        assertEquals(123L, command.leaseSecret)
        assertEquals(7, command.generation)
        assertEquals(12L, command.sequence)
        assertEquals(240L, command.durationMs)
        assertEquals(20f, command.firstFromXPx, 0.001f)
        assertEquals(150f, command.firstFromYPx, 0.001f)
        assertEquals(20f, command.firstToXPx, 0.001f)
        assertEquals(150f, command.firstToYPx, 0.001f)
        assertEquals(70f, command.secondFromXPx, 0.001f)
        assertEquals(140f, command.secondFromYPx, 0.001f)
        assertEquals(80f, command.secondToXPx, 0.001f)
        assertEquals(60f, command.secondToYPx, 0.001f)
    }

    @Test
    fun multiPathScopeCoversBothFingersWithoutCoveringSpaceBetweenThem() {
        val scope = AiActionScope.fromPaths(
            listOf(
                listOf(0.20 to 0.75, 0.20 to 0.40),
                listOf(0.80 to 0.75, 0.80 to 0.40)
            )
        )

        assertTrue(scope.contains(0.20, 0.55))
        assertTrue(scope.contains(0.80, 0.55))
        assertFalse(scope.contains(0.50, 0.55))
    }
}
