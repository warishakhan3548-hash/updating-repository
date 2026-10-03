package com.aaris.remoteassist.control

import org.junit.Assert.*
import org.junit.Test

class CommandLatencyTrackerTest {
    @Test fun samplesMatchSequenceAndIgnoreFailedUnknownAndDuplicateAcks() {
        val tracker = CommandLatencyTracker()
        for (i in 1L..20L) tracker.sent(i, 1000)
        for (i in 20L downTo 1L) tracker.acknowledged(i, true, 1000 + i * 10)
        tracker.acknowledged(20, true, 4000)
        tracker.acknowledged(99, true, 4000)
        tracker.sent(21, 1000); tracker.acknowledged(21, false, 2000)
        assertEquals("Command ACK p50=100ms p95=190ms n=20 (not screen latency)", tracker.summary())
        tracker.reset()
        assertTrue(tracker.summary().contains("waiting"))
    }

    @Test fun pendingCommandsAndRollingWindowAreBounded() {
        val tracker = CommandLatencyTracker()
        for (i in 1L..300L) tracker.sent(i, 1000)
        tracker.acknowledged(1, true, 1010)
        assertTrue(tracker.summary().contains("waiting"))
        for (i in 173L..300L) tracker.acknowledged(i, true, 1050)
        assertTrue(tracker.summary().contains("p95=50ms n=128"))
    }
}
