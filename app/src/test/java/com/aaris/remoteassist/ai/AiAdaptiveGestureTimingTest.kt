package com.aaris.remoteassist.ai

import com.aaris.remoteassist.control.GesturePathCommand
import com.aaris.remoteassist.control.SwipeCommand
import com.aaris.remoteassist.control.TwoFingerCommand
import com.aaris.remoteassist.session.LiveLease
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class AiAdaptiveGestureTimingTest {
    private val lease = LiveLease(
        sessionId = "session",
        leaseSecret = 77L,
        displayGeneration = 4
    )

    @Test
    fun defaultSwipeDurationScalesWithTravelDistance() {
        val short = AiActionTranslator.translate(
            JSONObject()
                .put("action", "swipe")
                .put("x", 0.50)
                .put("y", 0.50)
                .put("toX", 0.60)
                .put("toY", 0.50),
            lease,
            1L,
            1000,
            2000
        ) as SwipeCommand
        val long = AiActionTranslator.translate(
            JSONObject()
                .put("action", "swipe")
                .put("x", 0.10)
                .put("y", 0.50)
                .put("toX", 0.90)
                .put("toY", 0.50),
            lease,
            2L,
            1000,
            2000
        ) as SwipeCommand

        assertTrue(short.durationMs in 110L..335L)
        assertTrue(long.durationMs in 110L..335L)
        assertTrue(long.durationMs > short.durationMs)
    }

    @Test
    fun explicitDurationRemainsAuthoritative() {
        val swipe = AiActionTranslator.translate(
            JSONObject()
                .put("action", "swipe")
                .put("x", 0.10)
                .put("y", 0.80)
                .put("toX", 0.90)
                .put("toY", 0.20)
                .put("durationMs", 777),
            lease,
            3L,
            1000,
            2000
        ) as SwipeCommand

        assertEquals(777L, swipe.durationMs)
    }

    @Test
    fun precisionDragIsMoreDeliberateThanEquivalentSwipe() {
        val swipe = AiActionTranslator.translate(
            JSONObject()
                .put("action", "swipe")
                .put("x", 0.10)
                .put("y", 0.50)
                .put("toX", 0.90)
                .put("toY", 0.50),
            lease,
            4L,
            1000,
            2000
        ) as SwipeCommand
        val drag = AiActionTranslator.translate(
            JSONObject()
                .put("action", "drag")
                .put(
                    "points",
                    JSONArray()
                        .put(JSONObject().put("x", 0.10).put("y", 0.50))
                        .put(JSONObject().put("x", 0.90).put("y", 0.50))
                ),
            lease,
            5L,
            1000,
            2000
        ) as GesturePathCommand

        assertTrue(drag.durationMs > swipe.durationMs)
    }

    @Test
    fun curvedDragUsesWholePolylineRatherThanOnlyEndpoints() {
        val almostRoundTrip = AiActionTranslator.translate(
            JSONObject()
                .put("action", "drag")
                .put(
                    "points",
                    JSONArray()
                        .put(JSONObject().put("x", 0.10).put("y", 0.50))
                        .put(JSONObject().put("x", 0.85).put("y", 0.50))
                        .put(JSONObject().put("x", 0.12).put("y", 0.50))
                ),
            lease,
            6L,
            1000,
            2000
        ) as GesturePathCommand

        assertTrue(almostRoundTrip.durationMs >= 450L)
    }

    @Test
    fun twoFingerDefaultUsesTheFartherFinger() {
        val gesture = AiActionTranslator.translate(
            JSONObject()
                .put("action", "two_finger")
                .put("x", 0.45)
                .put("y", 0.50)
                .put("toX", 0.46)
                .put("toY", 0.50)
                .put("secondX", 0.80)
                .put("secondY", 0.50)
                .put("secondToX", 0.20)
                .put("secondToY", 0.50),
            lease,
            7L,
            1000,
            2000
        ) as TwoFingerCommand

        assertTrue(gesture.durationMs >= 280L)
    }
}
