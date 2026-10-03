package com.aaris.remoteassist.ai

import com.aaris.remoteassist.control.GesturePathCommand
import com.aaris.remoteassist.control.TwoFingerCommand
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AiAdvancedGestureTest {
    @Test
    fun curvedGestureUsesEveryWaypointAndPreservesDuration() {
        val args = JSONObject()
            .put("action", "gesture_path")
            .put("durationMs", 320)
            .put(
                "points",
                JSONArray()
                    .put(JSONObject().put("x", 0.10).put("y", 0.20))
                    .put(JSONObject().put("x", 0.35).put("y", 0.45))
                    .put(JSONObject().put("x", 0.70).put("y", 0.30))
            )

        val command = AiActionTranslator.translate(
            sessionId = "session",
            leaseSecret = 7L,
            generation = 3,
            sequence = 9L,
            widthPx = 1000,
            heightPx = 2000,
            args = args
        ) as GesturePathCommand

        assertEquals(3, command.points.size)
        assertEquals(320L, command.durationMs)
        assertEquals(100f, command.points[0].xPx, 0.01f)
        assertEquals(900f, command.points[1].yPx, 0.01f)
        assertEquals(700f, command.points[2].xPx, 0.01f)
    }

    @Test
    fun twoFingerMotionMapsBothPointersThroughExistingSecureCommandPath() {
        val args = JSONObject()
            .put("action", "two_finger")
            .put("durationMs", 450)
            .put("firstX", 0.40).put("firstY", 0.50)
            .put("firstToX", 0.25).put("firstToY", 0.50)
            .put("secondX", 0.60).put("secondY", 0.50)
            .put("secondToX", 0.75).put("secondToY", 0.50)

        val command = AiActionTranslator.translate(
            sessionId = "session",
            leaseSecret = 7L,
            generation = 3,
            sequence = 10L,
            widthPx = 1000,
            heightPx = 2000,
            args = args
        ) as TwoFingerCommand

        assertEquals(450L, command.durationMs)
        assertEquals(400f, command.firstFromXPx, 0.01f)
        assertEquals(250f, command.firstToXPx, 0.01f)
        assertEquals(600f, command.secondFromXPx, 0.01f)
        assertEquals(750f, command.secondToXPx, 0.01f)
    }

    @Test
    fun actionScopeFollowsCurveWithoutWatchingUnrelatedBoundingBoxPixels() {
        val scope = AiActionScope.path(
            listOf(
                0.10 to 0.80,
                0.50 to 0.30,
                0.90 to 0.80
            )
        )

        assertTrue(scope.contains(0.50, 0.30))
        assertTrue(scope.contains(0.30, 0.55))
        assertFalse(scope.contains(0.50, 0.78))
    }

    @Test
    fun twoFingerScopeCoversBothPathsWithoutInventingBridgeBetweenThem() {
        val scope = AiActionScope.paths(
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
