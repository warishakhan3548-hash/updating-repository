package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FallbackReadbackBudgetTest {
    @Test fun defaultEnvelopePreservesLegacyAndInteractiveQuality() {
        val budget = FallbackReadbackBudget()
        assertEquals(
            2560,
            budget.maxSidePx(
                baseSidePx = 2560,
                sourceWidthPx = 1440,
                sourceHeightPx = 3200
            )
        )
        assertEquals(
            1600,
            budget.maxSidePx(
                baseSidePx = 1600,
                sourceWidthPx = 720,
                sourceHeightPx = 1600
            )
        )
    }

    @Test fun isolatedSlowCopyDoesNotReduceResolution() {
        val budget = FallbackReadbackBudget()
        assertNull(budget.observe(70, 1_000))
        // A genuinely cheap sample breaks the overload streak.
        assertNull(budget.observe(8, 1_100))
        assertNull(budget.observe(70, 1_200))
        assertEquals(
            2560,
            budget.maxSidePx(2560, 1440, 3200)
        )
    }

    @Test fun oneFrameBudgetReadbackImmediatelyThrottlesFallbackCadence() {
        val budget = FallbackReadbackBudget()

        assertNull(budget.observe(17, 1_000))
        assertEquals(68L, budget.minimumIntervalMs())

        // Cheap readback removes only the fast cadence brake; spatial recovery
        // remains governed by its own slower hysteresis.
        assertNull(budget.observe(8, 1_100))
        assertEquals(0L, budget.minimumIntervalMs())
    }

    @Test fun expensiveReadbackDutyCycleIsBounded() {
        val budget = FallbackReadbackBudget()

        assertNull(budget.observe(40, 1_000))
        assertEquals(160L, budget.minimumIntervalMs())

        assertNull(budget.observe(200, 1_100))
        assertEquals(300L, budget.minimumIntervalMs())
    }

    @Test fun sustainedSlowCopiesReduceOnlyBoundedFallbackPixels() {
        val budget = FallbackReadbackBudget()
        assertNull(budget.observe(40, 1_000))
        assertEquals(1, budget.observe(42, 1_100))
        assertEquals(
            1920,
            budget.maxSidePx(2560, 1440, 3200)
        )
        assertEquals(
            1200,
            budget.maxSidePx(1600, 720, 1600)
        )

        // Sustained pressure may step down again, but never twice at once.
        assertNull(budget.observe(55, 1_150))
        assertNull(budget.observe(55, 1_200))
        assertEquals(
            1920,
            budget.maxSidePx(2560, 1440, 3200)
        )
        assertEquals(2, budget.observe(55, 3_100))
        assertEquals(
            1280,
            budget.maxSidePx(2560, 1440, 3200)
        )
        assertEquals(
            800,
            budget.maxSidePx(1600, 720, 1600)
        )
        assertNull(budget.observe(99, 3_150))
        assertEquals(
            1280,
            budget.maxSidePx(2560, 1440, 3200)
        )
    }

    @Test fun pressureNeverCrossesThe360ShortEdgeReadabilityFloor() {
        val budget = FallbackReadbackBudget()
        budget.observe(40, 1_000)
        budget.observe(40, 1_050)
        budget.observe(40, 3_100)
        budget.observe(40, 3_150)

        // A 1080x2400 source needs an 800px long side to preserve a 360px
        // short edge. The old 50% pressure rung returned 600px here.
        assertEquals(
            800,
            budget.maxSidePx(
                baseSidePx = 1200,
                sourceWidthPx = 1080,
                sourceHeightPx = 2400
            )
        )

        // 800 / 2400 * 1080 == 360 exactly.
        val deliveredShortEdge =
            1080.0 * 800.0 / 2400.0
        assertEquals(360.0, deliveredShortEdge, 0.001)
    }

    @Test fun recoveryRequiresEnoughFreshHealthySamplesAndHoldTime() {
        val budget = FallbackReadbackBudget()
        budget.observe(40, 1_000)
        budget.observe(40, 1_050)
        assertEquals(
            1920,
            budget.maxSidePx(2560, 1440, 3200)
        )

        repeat(10) {
            assertNull(budget.observe(8, 5_000L + it * 100L))
        }
        assertEquals(
            1920,
            budget.maxSidePx(2560, 1440, 3200)
        )

        // A pause invalidates the old votes; the first healthy callback cannot
        // recover quality on stale proof, even though the hold time has elapsed.
        assertNull(budget.observe(8, 20_000))
        assertEquals(
            1920,
            budget.maxSidePx(2560, 1440, 3200)
        )
        repeat(8) {
            assertNull(budget.observe(8, 20_100L + it * 100L))
        }
        assertEquals(0, budget.observe(8, 20_900))
        assertEquals(
            2560,
            budget.maxSidePx(2560, 1440, 3200)
        )
    }

    @Test fun disconnectedEvidenceAndResetDoNotLeakAcrossRecoverySessions() {
        val budget = FallbackReadbackBudget()
        budget.observe(45, 100)
        assertNull(budget.observe(45, 3_000))
        assertEquals(
            2560,
            budget.maxSidePx(2560, 1440, 3200)
        )
        assertEquals(1, budget.observe(45, 3_100))
        budget.reset()
        assertEquals(
            2560,
            budget.maxSidePx(2560, 1440, 3200)
        )
        assertEquals(0L, budget.minimumIntervalMs())
        assertNull(budget.observe(45, 50))
        assertEquals(
            2560,
            budget.maxSidePx(2560, 1440, 3200)
        )
    }

    @Test fun invalidMeasurementsHaveNoEffect() {
        val budget = FallbackReadbackBudget()
        assertNull(budget.observe(-1, 10))
        assertNull(budget.observe(40, -1))
        assertEquals(
            2560,
            budget.maxSidePx(2560, 1440, 3200)
        )
        assertEquals(0L, budget.minimumIntervalMs())
    }
}
