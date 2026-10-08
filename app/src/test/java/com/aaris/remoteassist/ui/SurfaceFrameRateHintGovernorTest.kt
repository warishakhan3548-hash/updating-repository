package com.aaris.remoteassist.ui

import com.aaris.remoteassist.webrtc.PresentationCadenceWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceFrameRateHintGovernorTest {
    @Test
    fun stablePassiveVideoVotesOnceForDisplayClassCadence() {
        val governor = SurfaceFrameRateHintGovernor(initialWindows = 3)
        val twentyFour = window(250, 6, 43)
        assertNull(governor.observe(twentyFour, 1_000))
        assertNull(governor.observe(twentyFour, 1_250))
        assertEquals(60, governor.observe(twentyFour, 1_500))
        assertEquals(60, governor.currentHintFps())

        // Network/capture throttling must never vote the display down to 15 Hz.
        repeat(30) {
            assertNull(governor.observe(window(500, 1, 500), 2_000L + it * 500L))
        }
        assertEquals(60, governor.currentHintFps())
    }

    @Test
    fun repeatedTapAndSwipeNeverSwitchRefreshMode() {
        val governor = SurfaceFrameRateHintGovernor()
        assertEquals(60, governor.beginInteraction())
        repeat(100) {
            assertNull(governor.endInteraction())
            assertNull(governor.beginInteraction())
            assertEquals(60, governor.currentHintFps())
            assertNull(governor.observe(window(200, 6, 35), it * 200L))
        }
        assertTrue(governor.reset())
        assertEquals(0, governor.currentHintFps())
    }

    @Test
    fun noHintUntilCleanConsecutivePresentationWindows() {
        val governor = SurfaceFrameRateHintGovernor(initialWindows = 2)
        val clean = window(167, 10, 18)
        val hitch = window(200, 6, 130)
        assertNull(governor.observe(clean, 1_000))
        assertNull(governor.observe(hitch, 1_200))
        assertNull(governor.observe(clean, 1_400))
        assertEquals(60, governor.observe(clean, 1_600))
    }

    @Test
    fun frozenOrSparseStreamCannotAdvertiseNewCadence() {
        val governor = SurfaceFrameRateHintGovernor(initialWindows = 1)
        assertNull(governor.observe(window(500, 1, 500), 1_000))
        assertNull(governor.observe(window(200, 6, 150), 1_200))
        assertNull(governor.observe(window(250, 6, 43), -1))
        assertEquals(0, governor.currentHintFps())
    }

    @Test
    fun resetRemovesSurfaceVoteAndRestartsMeasurement() {
        val governor = SurfaceFrameRateHintGovernor(initialWindows = 2)
        assertFalse(governor.reset())
        assertNull(governor.observe(window(167, 10, 18), 1_000))
        assertEquals(60, governor.observe(window(167, 10, 18), 1_200))
        assertTrue(governor.reset())
        assertFalse(governor.reset())
        assertNull(governor.observe(window(167, 10, 18), 1_400))
        assertEquals(60, governor.observe(window(167, 10, 18), 1_600))
    }

    @Test
    fun firstGestureHonorsCallerCeilingAndInvalidHint() {
        val governor = SurfaceFrameRateHintGovernor()
        assertNull(governor.beginInteraction(0))
        assertEquals(30, governor.beginInteraction(30))
        assertNull(governor.beginInteraction(60))
        assertNull(governor.endInteraction())
        assertEquals(30, governor.currentHintFps())
        governor.reset()
        assertEquals(60, governor.beginInteraction(120))
    }

    private fun window(intervalMs: Int, frames: Int, maxGapMs: Int) =
        PresentationCadenceWindow(intervalMs, frames, maxGapMs)
}
