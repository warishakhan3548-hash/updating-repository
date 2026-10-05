package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FastPresentationGovernorTest {
    @Test
    fun healthyLowerRateContentDoesNotLoseItsInteractiveCeiling() {
        for (sourceFps in listOf(15, 24, 30)) {
            val governor = FastPresentationGovernor(maxFps = 60, initialCap = 60)
            val sample = PresentationCadenceWindow(1_000, sourceFps, 1_000 / sourceFps + 1)
            repeat(12) { index ->
                assertFalse(governor.observe(sample, 60, 1_000L * (index + 1), sourceFps.toDouble()))
            }
            assertEquals(60, governor.cap)
            assertEquals(0, governor.highCadenceFailureCountForTest())
        }
    }

    @Test
    fun lowRateContentDoesNotProveHeadroomForSixtyFps() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 45)
        repeat(12) { index ->
            assertFalse(governor.observe(PresentationCadenceWindow(500, 15, 34), 60,
                500L * (index + 1), suppliedFps = 30.0))
        }
        assertEquals(45, governor.cap)
        repeat(3) { index ->
            assertFalse(governor.observe(healthy45, 60, 7_000L + index * 500L, suppliedFps = 45.0))
        }
        assertTrue(governor.observe(healthy45, 60, 8_500L, suppliedFps = 45.0))
        assertEquals(60, governor.cap)
    }

    @Test
    fun trueReceiverShortfallStillGetsFastReliefWithSourceMeasurement() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 60)
        assertTrue(governor.observe(pressured60, 60, 1_000L, suppliedFps = 60.0))
        assertEquals(45, governor.cap)
        assertEquals(1, governor.highCadenceFailureCountForTest())

        val stalled = FastPresentationGovernor(maxFps = 60, initialCap = 60)
        assertTrue(stalled.observe(PresentationCadenceWindow(500, 15, 180), 60, 1_000L, 60.0))
        assertEquals(30, stalled.cap)
    }

    @Test
    fun sparseSourceAndInvalidSourceEvidenceDoNotInventHealthyRecovery() {
        val sparse = FastPresentationGovernor(maxFps = 60, initialCap = 45)
        assertFalse(sparse.observe(PresentationCadenceWindow(1_000, 5, 200), 60, 1_000L, 5.0))
        assertEquals(45, sparse.cap)
        for (bad in listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0)) {
            val governor = FastPresentationGovernor(maxFps = 60, initialCap = 60)
            assertTrue(governor.observe(pressured60, 60, 1_000L, bad))
            assertEquals(45, governor.cap)
        }
    }

    private val healthy45 = PresentationCadenceWindow(
        intervalMs = 500,
        renderedFrames = 23,
        maxGapMs = 30
    )

    private val pressured60 = PresentationCadenceWindow(
        intervalMs = 500,
        renderedFrames = 20,
        maxGapMs = 90
    )

    @Test
    fun highCadenceHitchDropsSixtyToFortyFiveImmediately() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 60)

        val changed = governor.observe(
            window = pressured60,
            desiredFps = 60,
            nowMs = 1_000
        )

        assertTrue(changed)
        assertEquals(45, governor.cap)
        assertEquals(1, governor.highCadenceFailureCountForTest())
    }

    @Test
    fun severeRenderStallTakesStrongReliefStep() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 45)

        val changed = governor.observe(
            window = PresentationCadenceWindow(
                intervalMs = 500,
                renderedFrames = 16,
                maxGapMs = 180
            ),
            desiredFps = 60,
            nowMs = 1_000
        )

        assertTrue(changed)
        assertEquals(30, governor.cap)
        // A 45-fps failure is not counted against the later 60-fps probe.
        assertEquals(0, governor.highCadenceFailureCountForTest())
    }

    @Test
    fun oneOrdinaryFortyFiveFpsWindowDoesNotCascadeToThirty() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 45)

        val changed = governor.observe(
            window = PresentationCadenceWindow(
                intervalMs = 500,
                renderedFrames = 18,
                maxGapMs = 80
            ),
            desiredFps = 60,
            nowMs = 1_000
        )

        assertFalse(changed)
        assertEquals(45, governor.cap)
    }

    @Test
    fun twoConsecutivePressuredWindowsReduceFortyFiveToThirty() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 45)
        val pressured = PresentationCadenceWindow(
            intervalMs = 500,
            renderedFrames = 18,
            maxGapMs = 80
        )

        assertFalse(
            governor.observe(
                window = pressured,
                desiredFps = 60,
                nowMs = 500
            )
        )
        assertTrue(
            governor.observe(
                window = pressured,
                desiredFps = 60,
                nowMs = 1_000
            )
        )
        assertEquals(30, governor.cap)
    }

    @Test
    fun cleanFortyFiveWithoutFailureMemoryCautiouslyProbesSixty() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 45)

        repeat(3) { index ->
            assertFalse(
                governor.observe(
                    window = healthy45,
                    desiredFps = 60,
                    nowMs = 500L * (index + 1)
                )
            )
        }

        assertTrue(
            governor.observe(
                window = healthy45,
                desiredFps = 60,
                nowMs = 2_000
            )
        )
        assertEquals(60, governor.cap)
    }

    @Test
    fun failedSixtyProbeBacksOffNextRetryForTenSeconds() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 60)

        assertTrue(
            governor.observe(
                window = pressured60,
                desiredFps = 60,
                nowMs = 1_000
            )
        )
        assertEquals(45, governor.cap)

        // Plenty of healthy evidence is not enough before the remembered
        // high-cadence retry delay expires.
        var time = 1_500L
        while (time < 11_000L) {
            assertFalse(
                governor.observe(
                    window = healthy45,
                    desiredFps = 60,
                    nowMs = time
                )
            )
            time += 500L
        }

        assertTrue(
            governor.observe(
                window = healthy45,
                desiredFps = 60,
                nowMs = 11_000L
            )
        )
        assertEquals(60, governor.cap)
    }

    @Test
    fun repeatedSixtyFailureDoublesRetryDelay() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 60)

        assertTrue(governor.observe(pressured60, 60, 1_000L))
        // First failure: retry after 10 s.
        var time = 1_500L
        while (time < 11_000L) {
            governor.observe(healthy45, 60, time)
            time += 500L
        }
        assertTrue(governor.observe(healthy45, 60, 11_000L))
        assertEquals(60, governor.cap)

        // Fail the probe again; second retry must wait 20 s.
        assertTrue(governor.observe(pressured60, 60, 11_500L))
        assertEquals(2, governor.highCadenceFailureCountForTest())
        assertEquals(45, governor.cap)

        time = 12_000L
        while (time < 31_500L) {
            assertFalse(governor.observe(healthy45, 60, time))
            time += 500L
        }
        assertTrue(governor.observe(healthy45, 60, 31_500L))
        assertEquals(60, governor.cap)
    }

    @Test
    fun oldHighCadenceFailureMemoryExpires() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 60)

        assertTrue(governor.observe(pressured60, 60, 1_000L))
        assertEquals(1, governor.highCadenceFailureCountForTest())

        // After the memory horizon, four healthy windows may use the normal
        // cautious recovery interval rather than the old failure backoff.
        assertFalse(governor.observe(healthy45, 60, 121_000L))
        assertFalse(governor.observe(healthy45, 60, 121_500L))
        assertFalse(governor.observe(healthy45, 60, 122_000L))
        assertTrue(governor.observe(healthy45, 60, 122_500L))
        assertEquals(60, governor.cap)
        assertEquals(0, governor.highCadenceFailureCountForTest())
    }
}
