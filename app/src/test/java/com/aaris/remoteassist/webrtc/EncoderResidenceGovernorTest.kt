package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.StalenessShadowSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EncoderResidenceGovernorTest {
    private fun snapshot(
        evaluated: Long = 20,
        wouldDrop: Long = 0,
        latestMs: Double = 10.0,
        maxMs: Double = latestMs
    ) = StalenessShadowSnapshot(
        evaluatedFrames = evaluated,
        wouldDropFrames = wouldDrop,
        latestQueueDelayMs = latestMs,
        maxQueueDelayMs = maxMs
    )

    @Test
    fun sustainedModerateResidenceSoftens60To45() {
        val governor = EncoderResidenceGovernor(maxFps = 60, initialCap = 60)
        val pressured = snapshot(
            evaluated = 20,
            wouldDrop = 7,
            latestMs = 82.0,
            maxMs = 100.0
        )

        assertFalse(governor.observe(pressured, requestedFps = 60, nowMs = 0))
        assertTrue(governor.observe(pressured, requestedFps = 60, nowMs = 800))
        assertEquals(45, governor.cap)
    }

    @Test
    fun severeResidenceTakesStrongReliefStep() {
        val governor = EncoderResidenceGovernor(maxFps = 60, initialCap = 60)
        val severe = snapshot(
            evaluated = 20,
            wouldDrop = 14,
            latestMs = 120.0,
            maxMs = 180.0
        )

        assertTrue(governor.observe(severe, requestedFps = 60, nowMs = 1_000))
        assertEquals(30, governor.cap)
    }

    @Test
    fun cleanWindowsRecoverOneCadenceRung() {
        val governor = EncoderResidenceGovernor(maxFps = 60, initialCap = 60)
        val severe = snapshot(
            evaluated = 20,
            wouldDrop = 14,
            latestMs = 120.0,
            maxMs = 180.0
        )
        assertTrue(governor.observe(severe, requestedFps = 60, nowMs = 1_000))
        assertEquals(30, governor.cap)

        val healthy = snapshot(
            evaluated = 20,
            wouldDrop = 0,
            latestMs = 8.0,
            maxMs = 12.0
        )
        repeat(7) { index ->
            assertFalse(
                governor.observe(
                    healthy,
                    requestedFps = 60,
                    nowMs = 6_100L + index * 500L
                )
            )
        }

        assertTrue(
            governor.observe(
                healthy,
                requestedFps = 60,
                nowMs = 9_600L
            )
        )
        assertEquals(45, governor.cap)
    }

    @Test
    fun passiveQueuePressureEntersFreshnessModeBeforeCadenceDrops() {
        val governor = EncoderResidenceGovernor(maxFps = 60, initialCap = 60)
        val pressured = snapshot(
            evaluated = 20,
            wouldDrop = 6,
            latestMs = 82.0,
            maxMs = 100.0
        )

        assertFalse(governor.freshnessPriority)
        assertFalse(governor.observe(pressured, requestedFps = 60, nowMs = 0))

        // The first measured pressure window switches degradation/admission
        // preference, while the slower cadence cap still waits for hysteresis.
        assertTrue(governor.freshnessPriority)
        assertEquals(60, governor.cap)
    }

    @Test
    fun freshnessModeNeedsSustainedHealthyEvidenceToRelease() {
        val governor = EncoderResidenceGovernor(maxFps = 60, initialCap = 60)
        val pressured = snapshot(
            evaluated = 20,
            wouldDrop = 6,
            latestMs = 82.0,
            maxMs = 100.0
        )
        val healthy = snapshot(
            evaluated = 20,
            wouldDrop = 0,
            latestMs = 8.0,
            maxMs = 12.0
        )

        governor.observe(pressured, requestedFps = 60, nowMs = 0)
        assertTrue(governor.freshnessPriority)

        repeat(3) { index ->
            governor.observe(
                healthy,
                requestedFps = 60,
                nowMs = 1_500L + index * 500L
            )
            assertTrue(governor.freshnessPriority)
        }

        governor.observe(
            healthy,
            requestedFps = 60,
            nowMs = 3_000L
        )
        assertFalse(governor.freshnessPriority)
    }

    @Test
    fun sparseStaticWindowsReleaseFreshnessModeAndResetClearsIt() {
        val governor = EncoderResidenceGovernor(maxFps = 60, initialCap = 60)
        val pressured = snapshot(
            evaluated = 20,
            wouldDrop = 6,
            latestMs = 82.0,
            maxMs = 100.0
        )
        val sparse = snapshot(
            evaluated = 0,
            wouldDrop = 0,
            latestMs = 8.0,
            maxMs = 8.0
        )

        governor.observe(pressured, requestedFps = 60, nowMs = 0)
        repeat(4) { index ->
            governor.observe(
                sparse,
                requestedFps = 60,
                nowMs = 1_500L + index * 500L
            )
        }
        assertFalse(governor.freshnessPriority)

        governor.observe(pressured, requestedFps = 60, nowMs = 4_000L)
        assertTrue(governor.freshnessPriority)
        governor.resetFreshnessPriority()
        assertFalse(governor.freshnessPriority)
        assertEquals(60, governor.cap)
    }

    @Test
    fun tinySamplesDoNotChangeCadence() {
        val governor = EncoderResidenceGovernor(maxFps = 60, initialCap = 60)
        val tiny = snapshot(
            evaluated = 2,
            wouldDrop = 2,
            latestMs = 500.0,
            maxMs = 500.0
        )

        assertFalse(governor.observe(tiny, requestedFps = 60, nowMs = 10_000))
        assertEquals(60, governor.cap)
    }
}
