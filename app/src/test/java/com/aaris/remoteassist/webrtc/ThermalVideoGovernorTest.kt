package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ThermalVideoGovernorTest {
    @Test
    fun worseningThermalPressureReducesCadenceImmediately() {
        val governor = ThermalVideoGovernor(maxFps = 60)

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.WARM,
                1_000L
            )
        )
        assertEquals(45, governor.cap)

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.HOT,
                1_100L
            )
        )
        assertEquals(30, governor.cap)

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.CRITICAL,
                1_200L
            )
        )
        assertEquals(24, governor.cap)

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.EMERGENCY,
                1_300L
            )
        )
        assertEquals(15, governor.cap)
    }

    @Test
    fun coolingWaitsBeforeRaisingCadence() {
        val governor = ThermalVideoGovernor(maxFps = 60)

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.HOT,
                1_000L
            )
        )
        assertEquals(30, governor.cap)

        assertFalse(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                1_100L
            )
        )
        assertFalse(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                16_099L
            )
        )
        assertEquals(30, governor.cap)

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                16_100L
            )
        )
        assertEquals(45, governor.cap)
    }

    @Test
    fun recoveryIsOneRungAtATime() {
        val governor = ThermalVideoGovernor(maxFps = 60)

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.EMERGENCY,
                1_000L
            )
        )
        assertEquals(15, governor.cap)

        assertFalse(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                2_000L
            )
        )

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                17_000L
            )
        )
        assertEquals(20, governor.cap)

        assertFalse(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                26_999L
            )
        )
        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                27_000L
            )
        )
        assertEquals(24, governor.cap)
    }

    @Test
    fun maximumDeviceCadenceIsNeverExceeded() {
        val governor = ThermalVideoGovernor(maxFps = 45)

        assertFalse(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                1_000L
            )
        )
        assertEquals(45, governor.cap)

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.CRITICAL,
                2_000L
            )
        )
        assertEquals(24, governor.cap)

        governor.observe(
            ThermalVideoGovernor.Pressure.NORMAL,
            3_000L
        )
        governor.observe(
            ThermalVideoGovernor.Pressure.NORMAL,
            18_000L
        )
        assertEquals(30, governor.cap)
    }

    @Test
    fun renewedHeatCancelsPendingRecoveryAndTakesImmediateRelief() {
        val governor = ThermalVideoGovernor(maxFps = 60)

        governor.observe(
            ThermalVideoGovernor.Pressure.HOT,
            1_000L
        )
        governor.observe(
            ThermalVideoGovernor.Pressure.NORMAL,
            2_000L
        )

        assertTrue(
            governor.observe(
                ThermalVideoGovernor.Pressure.CRITICAL,
                10_000L
            )
        )
        assertEquals(24, governor.cap)

        assertFalse(
            governor.observe(
                ThermalVideoGovernor.Pressure.NORMAL,
                10_100L
            )
        )
        assertEquals(24, governor.cap)
    }
}
