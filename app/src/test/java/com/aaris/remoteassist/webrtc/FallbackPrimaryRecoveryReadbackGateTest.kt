package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FallbackPrimaryRecoveryReadbackGateTest {
    @Test
    fun decoderProgressGetsExactlyOneBoundedReadbackRunway() {
        val gate =
            FallbackPrimaryRecoveryReadbackGate(
                graceMs = 300L
            )

        gate.arm()
        assertFalse(gate.shouldSuppress(999L))
        assertTrue(gate.noteDecoderProgress(1_000L))
        assertTrue(gate.shouldSuppress(1_000L))
        assertTrue(gate.shouldSuppress(1_299L))
        assertFalse(gate.shouldSuppress(1_300L))

        // Repeated decoder telemetry in the same recovery episode must not
        // freeze compatibility video forever.
        assertFalse(gate.noteDecoderProgress(1_500L))
        assertFalse(gate.shouldSuppress(1_500L))
    }

    @Test
    fun newFallbackEpisodeRearmsThePrimaryRunway() {
        val gate =
            FallbackPrimaryRecoveryReadbackGate(
                graceMs = 200L
            )

        gate.arm()
        assertTrue(gate.noteDecoderProgress(100L))
        assertTrue(gate.shouldSuppress(299L))
        assertFalse(gate.shouldSuppress(300L))

        gate.stop()
        assertFalse(gate.shouldSuppress(150L))
        assertFalse(gate.noteDecoderProgress(400L))

        gate.arm()
        assertTrue(gate.noteDecoderProgress(500L))
        assertTrue(gate.shouldSuppress(699L))
        assertFalse(gate.shouldSuppress(700L))
    }

    @Test
    fun invalidTelemetryCannotConsumeTheOneShotGate() {
        val gate =
            FallbackPrimaryRecoveryReadbackGate(
                graceMs = 100L
            )

        gate.arm()
        assertFalse(gate.noteDecoderProgress(-1L))
        assertTrue(gate.noteDecoderProgress(50L))
        assertTrue(gate.shouldSuppress(50L))
    }

    @Test
    fun deadlineCalculationSaturatesInsteadOfOverflowing() {
        val gate =
            FallbackPrimaryRecoveryReadbackGate(
                graceMs = 300L
            )

        gate.arm()
        assertTrue(gate.noteDecoderProgress(Long.MAX_VALUE - 100L))
        assertTrue(gate.shouldSuppress(Long.MAX_VALUE - 1L))
        assertFalse(gate.shouldSuppress(Long.MAX_VALUE))
    }
}
