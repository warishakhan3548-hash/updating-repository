package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test

class DisplayCadencePolicyTest {
    @Test
    fun sixtyHzUsesUniformHighCadencePresentation() {
        val ladder = DisplayCadencePolicy.descending(60.0, 60)

        assertEquals(
            listOf(60, 30, 24, 20, 15),
            ladder
        )
        assertFalse(58 in ladder)
        assertFalse(55 in ladder)
        assertFalse(50 in ladder)
        assertFalse(45 in ladder)
        assertFalse(40 in ladder)
        assertFalse(36 in ladder)
        assertFalse(33 in ladder)
        assertEquals(
            30,
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
    fun ninetyHzUsesFortyFiveAsItsUniformHighCadenceRung() {
        val ladder = DisplayCadencePolicy.descending(90.0, 60)

        assertEquals(
            listOf(45, 30, 24, 20, 15),
            ladder
        )
        assertFalse(60 in ladder)
        assertEquals(
            45,
            DisplayCadencePolicy.nextLower(60, 90.0, ceilingFps = 60)
        )
    }

    @Test
    fun oneTwentyHzKeepsExactDisplayDivisors() {
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
    fun oneFortyFourHzGetsNativeFortyEightFpsRung() {
        val ladder = DisplayCadencePolicy.descending(144.0, 60)

        assertEquals(
            listOf(48, 36, 30, 24, 20, 15),
            ladder
        )
        assertEquals(
            48,
            DisplayCadencePolicy.nextLower(60, 144.0, ceilingFps = 60)
        )
    }

    @Test
    fun harmonicRateIsKeptOnHighRefreshDisplay() {
        val ladder = DisplayCadencePolicy.descending(165.0, 60)

        assertTrue(55 in ladder)
        assertTrue(33 in ladder)
        assertFalse(50 in ladder)
        assertEquals(
            55,
            DisplayCadencePolicy.nextLower(60, 165.0, ceilingFps = 60)
        )
    }

    @Test
    fun lowPressureRecoveryRungsRemainAvailable() {
        val ladder = DisplayCadencePolicy.descending(90.0, 30)

        assertEquals(
            listOf(30, 24, 20, 15),
            ladder
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
