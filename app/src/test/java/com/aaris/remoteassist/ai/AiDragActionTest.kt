package com.aaris.remoteassist.ai

import com.aaris.remoteassist.control.GesturePathCommand
import com.aaris.remoteassist.session.LiveLease
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AiDragActionTest {
    private val lease = LiveLease(
        sessionId = "session",
        leaseSecret = 123L,
        displayGeneration = 7
    )

    @Test
    fun translatorMapsCurvedDragOntoExistingGesturePath() {
        val args = JSONObject()
            .put("action", "drag")
            .put("durationMs", 420)
            .put(
                "points",
                JSONArray()
                    .put(JSONObject().put("x", 0.10).put("y", 0.80))
                    .put(JSONObject().put("x", 0.16).put("y", 0.55))
                    .put(JSONObject().put("x", 0.42).put("y", 0.30))
            )

        val command = AiActionTranslator.translate(
            args = args,
            lease = lease,
            sequence = 11L,
            width = 101,
            height = 201
        ) as GesturePathCommand

        assertEquals("session", command.sessionId)
        assertEquals(123L, command.leaseSecret)
        assertEquals(7, command.generation)
        assertEquals(11L, command.sequence)
        assertEquals(420L, command.durationMs)
        assertEquals(3, command.points.size)
        assertEquals(10f, command.points[0].xPx, 0.001f)
        assertEquals(160f, command.points[0].yPx, 0.001f)
        assertEquals(16f, command.points[1].xPx, 0.001f)
        assertEquals(110f, command.points[1].yPx, 0.001f)
        assertEquals(42f, command.points[2].xPx, 0.001f)
        assertEquals(60f, command.points[2].yPx, 0.001f)
    }

    @Test
    fun curvedScopeFollowsPolylineRatherThanItsBoundingBox() {
        val scope = AiActionScope.fromPath(
            listOf(
                0.10 to 0.80,
                0.15 to 0.30,
                0.70 to 0.30
            )
        )

        assertTrue(scope.contains(0.125, 0.55))
        assertTrue(scope.contains(0.45, 0.30))
        assertFalse(scope.contains(0.65, 0.75))
    }

    @Test
    fun translatorRejectsOutOfRangeOrUnderspecifiedDrag() {
        val tooShort = JSONObject()
            .put("action", "drag")
            .put("points", JSONArray().put(JSONObject().put("x", 0.1).put("y", 0.2)))
        assertThrows(IllegalArgumentException::class.java) {
            AiActionTranslator.translate(tooShort, lease, 1L, 100, 200)
        }

        val outOfRange = JSONObject()
            .put("action", "drag")
            .put(
                "points",
                JSONArray()
                    .put(JSONObject().put("x", 0.1).put("y", 0.2))
                    .put(JSONObject().put("x", 1.1).put("y", 0.3))
            )
        assertThrows(IllegalArgumentException::class.java) {
            AiActionTranslator.translate(outOfRange, lease, 1L, 100, 200)
        }
    }
}
