package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class CaptureCallbackTimingTrackerTest {
    @Test fun emitsStagePercentilesOnlyAfterEnoughSamplesAndTime() {
        val tracker = CaptureCallbackTimingTracker(
            reportWindowMs = 500L,
            minSamples = 4,
            sampleCapacity = 8
        )
        assertNull(tracker.record(1_000L, 1_000_000L, 2_000_000L))
        assertNull(tracker.record(1_100L, 2_000_000L, 1_000_000L))
        assertNull(tracker.record(1_200L, 3_000_000L, 8_000_000L))
        val batch = tracker.record(1_500L, 10_000_000L, 3_000_000L)!!
        val p = batch.summarizeAndRelease()!!
        assertEquals(4, p.samples)
        assertEquals(10_000L, p.ingressP95Us)
        assertEquals(10_000L, p.ingressP99Us)
        assertEquals(8_000L, p.auxiliaryP95Us)
        assertEquals(8_000L, p.auxiliaryP99Us)
    }

    @Test fun ringIsBoundedAndSampleWindowResetsAfterReport() {
        val tracker = CaptureCallbackTimingTracker(
            reportWindowMs = 100L,
            minSamples = 3,
            sampleCapacity = 4
        )
        repeat(8) {
            assertNull(tracker.record(1_000L + it, (it + 1L) * 1_000L, 0L))
        }
        val window =
            tracker.record(1_100L, 9_000L, 0L)!!
                .summarizeAndRelease()!!
        assertEquals(4, window.samples)
        assertEquals(9L, window.ingressP99Us)
        assertEquals(0L, window.auxiliaryP95Us)
        assertNull(tracker.record(1_101L, 1_000L, 5_000L))
        assertNull(tracker.record(1_110L, 1_000L, 5_000L))
        val second =
            tracker.record(1_201L, 1_000L, 5_000L)!!
                .summarizeAndRelease()!!
        assertEquals(5L, second.auxiliaryP99Us)
    }

    @Test fun negativeOrRewoundClockCannotProduceFalseDurations() {
        val tracker = CaptureCallbackTimingTracker(
            reportWindowMs = 10L,
            minSamples = 2,
            sampleCapacity = 3
        )
        assertNull(tracker.record(-1L, 100L, 100L))
        assertNull(tracker.record(1_000L, -3L, -7L))
        assertNull(tracker.record(900L, -3L, -7L))
        val result =
            tracker.record(910L, -3L, -7L)!!
                .summarizeAndRelease()!!
        assertEquals(0L, result.ingressP95Us)
        assertEquals(0L, result.auxiliaryP99Us)
    }

    @Test fun delayedConsumerDropsTelemetryInsteadOfBlockingCapture() {
        val tracker = CaptureCallbackTimingTracker(
            reportWindowMs = 10L,
            minSamples = 2,
            sampleCapacity = 3
        )
        assertNull(tracker.record(1_000L, 1_000L, 1_000L))
        val first = tracker.record(1_010L, 2_000L, 2_000L)
        assertNotNull(first)

        // The spare pair is owned by the outstanding batch. Capture keeps
        // accepting samples; it simply withholds another diagnostics batch.
        assertNull(tracker.record(1_020L, 3_000L, 3_000L))
        assertNull(tracker.record(1_030L, 4_000L, 4_000L))
        assertNull(tracker.record(1_040L, 5_000L, 5_000L))

        first!!.release()
        val recovered = tracker.record(1_050L, 6_000L, 6_000L)
        assertNotNull(recovered)
        assertEquals(3, recovered!!.summarizeAndRelease()!!.samples)
    }

    @Test fun sourceGapTailExposesProducerStarvationWithoutAttributingItToRtp() {
        val tracker = CaptureCallbackTimingTracker(
            reportWindowMs = 100L,
            minSamples = 4,
            sampleCapacity = 8
        )
        assertNull(tracker.record(1_000L, 1_000L, 2_000L, 1_000_000_000L))
        assertNull(tracker.record(1_030L, 1_000L, 2_000L, 1_030_000_000L))
        assertNull(tracker.record(1_060L, 1_000L, 2_000L, 1_060_000_000L))
        val report =
            tracker.record(1_600L, 1_000L, 2_000L, 1_600_000_000L)!!
                .summarizeAndRelease()!!
        assertEquals(4, report.samples)
        assertEquals(3, report.sourceGapSamples)
        assertEquals(540_000L, report.sourceGapP95Us)
        assertEquals(540_000L, report.sourceGapP99Us)
        assertEquals(1L, report.ingressP99Us)
        assertEquals(2L, report.auxiliaryP99Us)
    }

    @Test fun missingAndRewoundCaptureClocksDoNotProduceFakeGapSamples() {
        val tracker = CaptureCallbackTimingTracker(
            reportWindowMs = 10L,
            minSamples = 4,
            sampleCapacity = 8
        )
        assertNull(tracker.record(1_000L, 1_000L, 1_000L, 1_000_000_000L))
        assertNull(tracker.record(1_005L, 1_000L, 1_000L, 500_000_000L))
        assertNull(tracker.record(1_010L, 1_000L, 1_000L))
        val report =
            tracker.record(1_020L, 1_000L, 1_000L, 520_000_000L)!!
                .summarizeAndRelease()!!
        assertEquals(1, report.sourceGapSamples)
        assertEquals(20_000L, report.sourceGapP95Us)
        assertEquals(20_000L, report.sourceGapP99Us)
    }

    @Test fun lowSourceFpsStillClosesDefaultTenSecondDiagnosticWindow() {
        val tracker = CaptureCallbackTimingTracker()
        repeat(10) { index ->
            assertNull(
                tracker.record(
                    nowMs = 1_000L + index * 1_000L,
                    primaryIngressNs = 5_000L,
                    auxiliarySinksNs = 10_000L,
                    callbackStartedNs = (index + 1L) * 1_000_000_000L
                )
            )
        }
        val result =
            tracker.record(11_000L, 5_000L, 10_000L, 11_000_000_000L)!!
                .summarizeAndRelease()!!
        assertEquals(11, result.samples)
        assertEquals(10, result.sourceGapSamples)
        assertEquals(1_000_000L, result.sourceGapP99Us)
    }
}
