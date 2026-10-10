package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test

class DisplayCadencePolicyTest {
    @Test
    fun sixtyHzAvoidsLongBeatNearRefreshRungs() {
        val ladder = DisplayCadencePolicy.descending(60.0, 60)

        assertEquals(
            listOf(60, 48, 45, 40, 36, 30, 24, 20, 15),
            ladder
        )
        assertFalse(58 in ladder)
        assertFalse(55 in ladder)
        assertFalse(50 in ladder)
        assertFalse(33 in ladder)
        assertEquals(
            48,
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
            listOf(60, 54, 45, 36, 30, 24, 20, 15),
            ladder
        )
        assertEquals(
            54,
            DisplayCadencePolicy.nextLower(60, 90.0, ceilingFps = 60)
        )
    }

    @Test
    fun oneTwentyHzUsesDisplayCompatibleHighCadenceRungs() {
        val ladder = DisplayCadencePolicy.descending(120.0, 60)

        assertEquals(
            listOf(60, 48, 40, 30, 24, 20, 15),
            ladder
        )
        assertEquals(
            48,
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
