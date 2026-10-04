package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FastPresentationGovernorTest {
    @Test
    fun highCadenceHitchDropsSixtyToFortyFiveImmediately() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 60)

        val changed = governor.observe(
            window = PresentationCadenceWindow(
                intervalMs = 500,
                renderedFrames = 20,
                maxGapMs = 90
            ),
            desiredFps = 60,
            nowMs = 1_000
        )

        assertTrue(changed)
        assertEquals(45, governor.cap)
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
    fun sustainedHealthyPresentationCautiouslyProbesSixty() {
        val governor = FastPresentationGovernor(maxFps = 60, initialCap = 45)

        repeat(3) { index ->
            assertFalse(
                governor.observe(
                    window = PresentationCadenceWindow(500, 23, 30),
                    desiredFps = 60,
                    nowMs = 500L * (index + 1)
                )
            )
        }

        assertTrue(
            governor.observe(
                window = PresentationCadenceWindow(500, 23, 30),
                desiredFps = 60,
                nowMs = 2_000
            )
        )
        assertEquals(60, governor.cap)
    }
}
