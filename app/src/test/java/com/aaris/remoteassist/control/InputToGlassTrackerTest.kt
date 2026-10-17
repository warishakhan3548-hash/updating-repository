package com.aaris.remoteassist.control

import org.junit.Assert.*
import org.junit.Test

class InputToGlassTrackerTest {
    @Test
    fun appliedAckCompletesOnNextRealPresentation() {
        val tracker = InputToGlassTracker()
        tracker.applied(
            AppliedCommandAck(
                sequence = 7,
                sentAtMs = 1_000,
                acknowledgedAtMs = 1_080
            )
        )

        assertNull(tracker.onPresented(1_079))
        val sample = checkNotNull(tracker.onPresented(1_100))
        assertEquals(7L, sample.sequence)
        assertEquals(100, sample.upperBoundMs)
        assertEquals(80, sample.commandAckMs)
        assertEquals(20, sample.postAckPresentMs)
        assertNull(tracker.onPresented(1_116))
    }

    @Test
    fun newestAppliedCommandWinsBeforeNextSwap() {
        val tracker = InputToGlassTracker()
        tracker.applied(AppliedCommandAck(1, 1_000, 1_050))
        tracker.applied(AppliedCommandAck(2, 1_020, 1_070))

        val sample = checkNotNull(tracker.onPresented(1_090))
        assertEquals(2L, sample.sequence)
        assertEquals(70, sample.upperBoundMs)
        assertEquals(50, sample.commandAckMs)
        assertEquals(20, sample.postAckPresentMs)
    }

    @Test
    fun staleOutOfOrderAndImpossibleSamplesAreIgnored() {
        val tracker = InputToGlassTracker()
        tracker.applied(AppliedCommandAck(5, 1_000, 1_040))
        checkNotNull(tracker.onPresented(1_060))

        tracker.applied(AppliedCommandAck(4, 1_100, 1_120))
        assertNull(tracker.onPresented(1_140))

        tracker.applied(
            AppliedCommandAck(
                sequence = 6,
                sentAtMs = 0,
                acknowledgedAtMs = 31_000
            )
        )
        assertNull(tracker.onPresented(31_010))
    }

    @Test
    fun rollingHistoryIsRecordedAfterLeavingTheRenderFastPath() {
        val tracker = InputToGlassTracker()
        tracker.applied(
            AppliedCommandAck(
                sequence = 1,
                sentAtMs = 1_000,
                acknowledgedAtMs = 1_040
            )
        )

        val sample = checkNotNull(tracker.onPresented(1_060))

        // onPresented() models the EGL render lane and must not take the
        // rolling-history monitor. History is committed by the session lane.
        assertTrue(tracker.summary().contains("waiting"))
        tracker.record(sample)
        assertTrue(tracker.summary().contains("n=1"))
        assertTrue(tracker.summary().contains("postAck p95=20ms"))
    }

    @Test
    fun summaryUsesBoundedRollingPhotonSamples() {
        val tracker = InputToGlassTracker()
        for (i in 1L..80L) {
            val sent = 1_000L + i * 100
            tracker.applied(
                AppliedCommandAck(
                    sequence = i,
                    sentAtMs = sent,
                    acknowledgedAtMs = sent + 40
                )
            )
            tracker.record(
                checkNotNull(tracker.onPresented(sent + 60))
            )
        }
        val summary = tracker.summary()
        assertTrue(summary.contains("n=64"))
        assertTrue(summary.contains("postAck p95=20ms"))
        tracker.reset()
        assertTrue(tracker.summary().contains("waiting"))
    }
}
