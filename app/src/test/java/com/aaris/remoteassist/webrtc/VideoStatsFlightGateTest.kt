package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test

class VideoStatsFlightGateTest {
    @Test fun oneNativeStatsRequestAtATimeDuringNormalOperation() {
        val gate = VideoStatsFlightGate(timeoutMs = 4_000L)
        val first = checkNotNull(gate.begin(1_000L))
        assertNull(gate.begin(1_500L))
        assertTrue(gate.isCurrent(first))
        assertTrue(gate.finish(first))
        val second = checkNotNull(gate.begin(1_501L))
        assertTrue(second != first)
        assertTrue(gate.finish(second))
    }

    @Test fun reconnectCanRestartTelemetryBeforeOldCallbackReturns() {
        val gate = VideoStatsFlightGate()
        val beforeDisconnect = checkNotNull(gate.begin(1_000L))
        gate.reset()
        val afterReconnect = checkNotNull(gate.begin(1_100L))
        assertFalse(gate.isCurrent(beforeDisconnect))
        assertFalse(gate.finish(beforeDisconnect))
        assertTrue(gate.isCurrent(afterReconnect))
        assertNull(gate.begin(1_200L))
        assertTrue(gate.finish(afterReconnect))
    }

    @Test fun staleCallbackCannotFreeTheNewerNativeRequest() {
        val gate = VideoStatsFlightGate(timeoutMs = 4_000L)
        val old = checkNotNull(gate.begin(0L))
        assertNull(gate.begin(3_999L))
        val replacement = checkNotNull(gate.begin(4_000L))
        assertFalse(gate.isCurrent(old))
        assertFalse(gate.finish(old))
        assertNull(gate.begin(4_001L))
        assertTrue(gate.finish(replacement))
    }

    @Test fun synchronousGetStatsFailureCanReleaseItsFlight() {
        val gate = VideoStatsFlightGate()
        val failed = checkNotNull(gate.begin(900L))
        assertTrue(gate.finish(failed))
        assertNotNull(gate.begin(901L))
    }

    @Test fun reversedClockStartsNewFlightRatherThanFreezing() {
        val gate = VideoStatsFlightGate()
        val old = checkNotNull(gate.begin(10_000L))
        val fresh = checkNotNull(gate.begin(50L))
        assertFalse(gate.isCurrent(old))
        assertTrue(gate.isCurrent(fresh))
    }

    @Test fun rejectsInvalidTimeAndTimeout() {
        val gate = VideoStatsFlightGate()
        assertNull(gate.begin(-1L))
        assertThrows(IllegalArgumentException::class.java) {
            VideoStatsFlightGate(timeoutMs = 100L)
        }
    }
}
