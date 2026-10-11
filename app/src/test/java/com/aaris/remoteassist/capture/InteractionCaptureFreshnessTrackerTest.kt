package com.aaris.remoteassist.capture

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InteractionCaptureFreshnessTrackerTest {
    @Test
    fun twoConsecutiveCausalMissesProveShortLivedStarvation() {
        val tracker = InteractionCaptureFreshnessTracker()

        tracker.observe(forcedRefresh = true, nowMs = 100L)
        assertFalse(tracker.isStarved(100L))

        tracker.observe(forcedRefresh = true, nowMs = 116L)
        assertTrue(tracker.isStarved(116L))
        assertTrue(tracker.isStarved(1_000L))
        assertFalse(tracker.isStarved(1_400L))
    }

    @Test
    fun naturalPostInputFrameImmediatelyClearsPressure() {
        val tracker = InteractionCaptureFreshnessTracker()

        tracker.observe(forcedRefresh = true, nowMs = 100L)
        tracker.observe(forcedRefresh = true, nowMs = 116L)
        assertTrue(tracker.isStarved(116L))

        tracker.observe(forcedRefresh = false, nowMs = 132L)
        assertFalse(tracker.isStarved(132L))
    }

    @Test
    fun unrelatedMissesDoNotAccumulateAcrossLongGaps() {
        val tracker = InteractionCaptureFreshnessTracker()

        tracker.observe(forcedRefresh = true, nowMs = 100L)
        tracker.observe(forcedRefresh = true, nowMs = 500L)

        assertFalse(tracker.isStarved(500L))
    }
}
