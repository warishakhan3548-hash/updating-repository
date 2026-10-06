package com.aaris.remoteassist.ui

import com.aaris.remoteassist.webrtc.PresentationCadenceWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceFrameRateHintGovernorTest {
    @Test
    fun stableSixtyFpsNeedsMultipleCleanWindowsBeforeHinting() {
        val governor =
            SurfaceFrameRateHintGovernor(
                initialWindows = 3,
                switchWindows = 4,
                minSwitchIntervalMs = 2_500L
            )
        val sixty = window(intervalMs = 167, frames = 10, maxGapMs = 18)

        assertNull(governor.observe(sixty, 1_000L))
        assertNull(governor.observe(sixty, 1_200L))
        assertEquals(60, governor.observe(sixty, 1_400L))
        assertEquals(60, governor.currentHintFps())
    }

    @Test
    fun oneRenderHitchCannotChangeAnEstablishedHint() {
        val governor =
            SurfaceFrameRateHintGovernor(
                initialWindows = 2,
                switchWindows = 3,
                minSwitchIntervalMs = 0L
            )
        val sixty = window(167, 10, 18)
        governor.observe(sixty, 1_000L)
        assertEquals(60, governor.observe(sixty, 1_200L))

        val hitch = window(200, 6, 130)
        assertNull(governor.observe(hitch, 1_400L))
        assertEquals(60, governor.currentHintFps())
    }

    @Test
    fun sustainedCadenceChangeIsRateLimitedAndThenApplied() {
        val governor =
            SurfaceFrameRateHintGovernor(
                initialWindows = 1,
                switchWindows = 3,
                minSwitchIntervalMs = 2_500L
            )
        assertEquals(60, governor.observe(window(167, 10, 18), 1_000L))

        val fortyFive = window(178, 8, 24)
        assertNull(governor.observe(fortyFive, 1_300L))
        assertNull(governor.observe(fortyFive, 1_500L))
        assertNull(governor.observe(fortyFive, 1_700L))
        assertEquals(60, governor.currentHintFps())

        assertEquals(45, governor.observe(fortyFive, 3_600L))
        assertEquals(45, governor.currentHintFps())
    }

    @Test
    fun resetReportsOnlyEstablishedHintAndRequiresFreshEvidenceAgain() {
        val governor =
            SurfaceFrameRateHintGovernor(
                initialWindows = 2,
                switchWindows = 2,
                minSwitchIntervalMs = 0L
            )
        val sixty = window(167, 10, 18)

        assertFalse(governor.reset())
        assertNull(governor.observe(sixty, 1_000L))
        assertEquals(60, governor.observe(sixty, 1_200L))
        assertTrue(governor.reset())
        assertEquals(0, governor.currentHintFps())
        assertFalse(governor.reset())

        assertNull(governor.observe(sixty, 1_400L))
        assertEquals(60, governor.observe(sixty, 1_600L))
    }

    @Test
    fun interactionBurstOverridesLearnedHintAndRestoresNewestMeasuredCadence() {
        val governor =
            SurfaceFrameRateHintGovernor(
                initialWindows = 1,
                switchWindows = 1,
                minSwitchIntervalMs = 0L
            )

        assertEquals(
            30,
            governor.observe(
                window(200, 6, 35),
                1_000L
            )
        )

        assertEquals(60, governor.beginInteraction())
        assertEquals(60, governor.currentHintFps())

        // Presentation evidence continues to be learned, but it must not
        // fight the temporary high-refresh Surface request mid-gesture.
        assertNull(
            governor.observe(
                window(178, 8, 24),
                1_200L
            )
        )
        assertEquals(60, governor.currentHintFps())

        assertEquals(45, governor.endInteraction())
        assertEquals(45, governor.currentHintFps())
    }

    @Test
    fun interactionBurstNeverRequestsAboveRealtimeVideoCeiling() {
        val governor =
            SurfaceFrameRateHintGovernor(
                initialWindows = 1,
                switchWindows = 1,
                minSwitchIntervalMs = 0L
            )

        assertEquals(60, governor.beginInteraction(120))
        assertEquals(60, governor.currentHintFps())
        assertNull(governor.beginInteraction(120))

        assertEquals(0, governor.endInteraction())
        assertEquals(0, governor.currentHintFps())
    }

    @Test
    fun commonVideoCadencesQuantizeToCaptureLadder() {
        val governor =
            SurfaceFrameRateHintGovernor(
                initialWindows = 1,
                switchWindows = 1,
                minSwitchIntervalMs = 0L
            )

        assertEquals(24, governor.observe(window(250, 6, 43), 1_000L))
        assertEquals(30, governor.observe(window(200, 6, 35), 1_100L))
        assertEquals(45, governor.observe(window(178, 8, 24), 1_200L))
    }

    @Test
    fun unstableOrUnknownCadenceDoesNotProduceRefreshChurn() {
        val governor =
            SurfaceFrameRateHintGovernor(
                initialWindows = 2,
                switchWindows = 2,
                minSwitchIntervalMs = 0L
            )

        assertNull(governor.observe(window(160, 8, 95), 1_000L))
        assertNull(governor.observe(window(160, 8, 95), 1_200L))
        assertEquals(0, governor.currentHintFps())

        governor.observe(window(167, 10, 18), 1_400L)
        assertEquals(60, governor.observe(window(167, 10, 18), 1_600L))

        assertNull(governor.observe(window(178, 8, 24), 1_800L))
        assertNull(governor.observe(window(167, 10, 18), 2_000L))
        assertNull(governor.observe(window(178, 8, 24), 2_200L))
        assertEquals(60, governor.currentHintFps())
    }

    private fun window(
        intervalMs: Int,
        frames: Int,
        maxGapMs: Int
    ) = PresentationCadenceWindow(
        intervalMs = intervalMs,
        renderedFrames = frames,
        maxGapMs = maxGapMs
    )
}
