package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test

class DisplayCadencePolicyTest {
    @Test
    fun sixtyHzAvoidsLongBeatNearRefreshRungs() {
        val ladder = DisplayCadencePolicy.descending(60.0, 60)

        assertEquals(
            listOf(60, 50, 45, 40, 36, 30, 24, 20, 15),
            ladder
        )
        assertFalse(58 in ladder)
        assertFalse(55 in ladder)
        assertTrue(50 in ladder)
        assertFalse(33 in ladder)
        assertEquals(
            50,
            DisplayCadencePolicy.nextLower(60, 60.0, ceilingFps = 60)
        )
    }

    @Test
    fun fractionalSixtyHzNormalizesToNominalDisplayClock() {
        assertEquals(
            DisplayCadencePolicy.descending(60.0, 60),
            DisplayCadencePolicy.descending(59.94, 60)
        )
    }

    @Test
    fun ninetyHzUsesShortRepeatRatios() {
        val ladder = DisplayCadencePolicy.descending(90.0, 60)

        assertEquals(
            listOf(60, 45, 36, 30, 24, 20, 15),
            ladder
        )
        assertEquals(
            45,
            DisplayCadencePolicy.nextLower(60, 90.0, ceilingFps = 60)
        )
    }

    @Test
    fun oneTwentyHzUsesDisplayCompatibleHighCadenceRungs() {
        val ladder = DisplayCadencePolicy.descending(120.0, 60)

        assertEquals(
            listOf(60, 40, 30, 24, 20, 15),
            ladder
        )
        assertEquals(
            40,
            DisplayCadencePolicy.nearestAtOrBelow(
                limitFps = 55,
                refreshRateHz = 120.0,
                ceilingFps = 60
            )
        )
    }

    @Test
    fun aRateIsKeptWhenItIsActuallyHarmonicOnThatDisplay() {
        val ladder = DisplayCadencePolicy.descending(165.0, 60)

        assertTrue(55 in ladder)
        assertEquals(
            55,
            DisplayCadencePolicy.nextLower(60, 165.0, ceilingFps = 60)
        )
    }

    @Test
    fun ninetyHzPromotionStopsAtTheFortyFiveFpsHarmonic() {
        assertEquals(
            36,
            DisplayCadencePolicy.nextHigher(
                currentFps = 30,
                refreshRateHz = 90.0,
                ceilingFps = 60,
                floorFps = 30
            )
        )
        assertEquals(
            45,
            DisplayCadencePolicy.nextHigher(
                currentFps = 36,
                refreshRateHz = 90.0,
                ceilingFps = 60,
                floorFps = 30
            )
        )
        assertNull(
            DisplayCadencePolicy.nextHigher(
                currentFps = 45,
                refreshRateHz = 90.0,
                ceilingFps = 60,
                floorFps = 30
            )
        )
    }

    @Test
    fun oneFortyFourHzCanPromoteToExactFortyEightFpsWithoutAddingAReliefRung() {
        assertEquals(
            36,
            DisplayCadencePolicy.nextHigher(
                currentFps = 30,
                refreshRateHz = 144.0,
                ceilingFps = 60,
                floorFps = 30
            )
        )
        assertEquals(
            48,
            DisplayCadencePolicy.nextHigher(
                currentFps = 36,
                refreshRateHz = 144.0,
                ceilingFps = 60,
                floorFps = 30
            )
        )
        assertNull(
            DisplayCadencePolicy.nextHigher(
                currentFps = 48,
                refreshRateHz = 144.0,
                ceilingFps = 60,
                floorFps = 30
            )
        )

        // Pressure relief keeps the historical short-repeat ladder unchanged.
        assertEquals(
            36,
            DisplayCadencePolicy.nextLower(
                currentFps = 48,
                refreshRateHz = 144.0,
                floorFps = 30,
                ceilingFps = 60
            )
        )
    }

    @Test
    fun encoderCeilingBelowAnyExactHarmonicKeepsExistingFineSteps() {
        assertEquals(
            36,
            DisplayCadencePolicy.nextHigher(
                currentFps = 30,
                refreshRateHz = 60.0,
                ceilingFps = 45,
                floorFps = 30
            )
        )
    }

    @Test
    fun sixtyHzSourceRejectsUnevenHighCadenceFrameSelection() {
        val ladder =
            DisplayCadencePolicy.descending(
                refreshRateHz = 60.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )

        assertEquals(
            listOf(60, 30, 24, 20, 15),
            ladder
        )
        assertFalse(50 in ladder)
        assertFalse(45 in ladder)
        assertFalse(40 in ladder)
        assertFalse(36 in ladder)
    }

    @Test
    fun sourceClockOwnsCaptureCadenceWhenDisplayClockDiffers() {
        val ladder =
            DisplayCadencePolicy.descending(
                refreshRateHz = 60.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 144.0
            )

        assertEquals(
            listOf(48, 36, 30, 24, 20, 15),
            ladder
        )
        assertEquals(
            36,
            DisplayCadencePolicy.nextHigher(
                currentFps = 30,
                refreshRateHz = 60.0,
                ceilingFps = 60,
                floorFps = 30,
                sourceRefreshRateHz = 144.0
            )
        )
        assertEquals(
            48,
            DisplayCadencePolicy.nextHigher(
                currentFps = 36,
                refreshRateHz = 60.0,
                ceilingFps = 60,
                floorFps = 30,
                sourceRefreshRateHz = 144.0
            )
        )
    }

    @Test
    fun controllerClockCapsCapacityWithoutPhaseLockingTheProducer() {
        assertEquals(
            listOf(60, 40, 30, 24, 20, 15),
            DisplayCadencePolicy.descending(
                refreshRateHz = 60.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 120.0
            )
        )
        assertEquals(
            40,
            DisplayCadencePolicy.nextLower(
                currentFps = 60,
                refreshRateHz = 60.0,
                floorFps = 30,
                ceilingFps = 60,
                sourceRefreshRateHz = 120.0
            )
        )

        assertEquals(
            listOf(45, 30, 24, 20, 15),
            DisplayCadencePolicy.descending(
                refreshRateHz = 90.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 90.0
            )
        )
    }

    @Test
    fun sixtyHzSourceKeepsSixtyUniqueFramesOnNinetyHzController() {
        assertEquals(
            60,
            DisplayCadencePolicy.nextHigher(
                currentFps = 30,
                refreshRateHz = 90.0,
                ceilingFps = 60,
                floorFps = 30,
                sourceRefreshRateHz = 60.0
            )
        )

        assertEquals(
            listOf(60, 30, 24, 20, 15),
            DisplayCadencePolicy.descending(
                refreshRateHz = 90.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
    }

    @Test
    fun oneTwentyHzSourceDoesNotCollapseOnNinetyHzController() {
        assertEquals(
            listOf(60, 40, 30, 24, 20, 15),
            DisplayCadencePolicy.descending(
                refreshRateHz = 90.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 120.0
            )
        )
        assertEquals(
            40,
            DisplayCadencePolicy.nextHigher(
                currentFps = 30,
                refreshRateHz = 90.0,
                ceilingFps = 60,
                floorFps = 30,
                sourceRefreshRateHz = 120.0
            )
        )
        assertEquals(
            60,
            DisplayCadencePolicy.nextHigher(
                currentFps = 40,
                refreshRateHz = 90.0,
                ceilingFps = 60,
                floorFps = 30,
                sourceRefreshRateHz = 120.0
            )
        )
    }

    @Test
    fun nonHarmonicProfileCeilingIsQuantizedBeforeFirstHealthWindow() {
        assertEquals(
            30,
            DisplayCadencePolicy.nearestAtOrBelow(
                limitFps = 45,
                refreshRateHz = null,
                ceilingFps = 45,
                sourceRefreshRateHz = 60.0
            )
        )
        assertEquals(
            45,
            DisplayCadencePolicy.nearestAtOrBelow(
                limitFps = 45,
                refreshRateHz = null,
                ceilingFps = 45,
                sourceRefreshRateHz = 90.0
            )
        )
        assertEquals(
            36,
            DisplayCadencePolicy.nearestAtOrBelow(
                limitFps = 45,
                refreshRateHz = null,
                ceilingFps = 45,
                sourceRefreshRateHz = 144.0
            )
        )
    }

    @Test
    fun pressureReliefAvoidsSixtyToThirtyCliffOnSixtyHzPair() {
        assertEquals(
            listOf(60, 50, 45, 40, 36, 30, 24, 20, 15),
            DisplayCadencePolicy.pressureReliefDescending(
                refreshRateHz = 60.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
        assertEquals(
            50,
            DisplayCadencePolicy.nextLower(
                currentFps = 60,
                refreshRateHz = 60.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
        assertEquals(
            45,
            DisplayCadencePolicy.nearestPressureReliefAtOrBelow(
                limitFps = 47,
                refreshRateHz = 60.0,
                ceilingFps = 60,
                floorFps = 30,
                sourceRefreshRateHz = 60.0
            )
        )

        // Steady-state admission stays strict: pressure relief must not leak into
        // startup/promotion and create avoidable producer cadence jitter.
        assertEquals(
            listOf(60, 30, 24, 20, 15),
            DisplayCadencePolicy.descending(
                refreshRateHz = 60.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
    }

    @Test
    fun mixedRefreshControllerDoesNotOverConstrainPressureRelief() {
        assertEquals(
            listOf(60, 50, 45, 40, 36, 30, 24, 20, 15),
            DisplayCadencePolicy.pressureReliefDescending(
                refreshRateHz = 90.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
        assertEquals(
            50,
            DisplayCadencePolicy.nextLower(
                currentFps = 60,
                refreshRateHz = 90.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
    }

    @Test
    fun oneSixtyFiveHzControllerCannotCollapseKnownSixtyHzSource() {
        assertEquals(
            50,
            DisplayCadencePolicy.nextLower(
                currentFps = 60,
                refreshRateHz = 165.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
        assertEquals(
            listOf(60, 50, 45, 40, 36, 30, 24, 20, 15),
            DisplayCadencePolicy.pressureReliefDescending(
                refreshRateHz = 165.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
    }

    @Test
    fun exactDisplayReliefHarmonicCanFillLegacyLadderGap() {
        assertTrue(
            48 in DisplayCadencePolicy.pressureReliefDescending(
                refreshRateHz = 96.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
        assertEquals(
            48,
            DisplayCadencePolicy.nextLower(
                currentFps = 60,
                refreshRateHz = 96.0,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
    }

    @Test
    fun sourceClockStillProtectsCadenceBeforeControllerRefreshArrives() {
        assertEquals(
            listOf(60, 30, 24, 20, 15),
            DisplayCadencePolicy.descending(
                refreshRateHz = null,
                ceilingFps = 60,
                sourceRefreshRateHz = 60.0
            )
        )
    }

    @Test
    fun unknownDisplayPreservesLegacyAdaptationExactly() {
        assertEquals(
            listOf(60, 58, 55, 50, 45, 40, 36, 33, 30, 24, 20, 15),
            DisplayCadencePolicy.descending(null, 60)
        )
        assertEquals(
            58,
            DisplayCadencePolicy.nextLower(60, null, ceilingFps = 60)
        )
    }
}
