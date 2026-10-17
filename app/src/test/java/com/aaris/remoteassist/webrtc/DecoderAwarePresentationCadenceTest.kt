package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Glass cadence must separate genuine EGL stalls from a static/idle producer.
 * Decoder callback counts are passed by the production VideoSink, without
 * retaining frames or inserting any work into the video render queue.
 */
class DecoderAwarePresentationCadenceTest {
    @Test fun quietScreenResumesWithoutFalseMultiSecondRenderPressure() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000L, decodedSequence = 1L))

        // No decoded frame arrived while the remote screen stayed unchanged.
        // The first new swap is an anchor, NOT a 2.5 second EGL stall.
        assertNull(tracker.onPresented(3_500L, decodedSequence = 2L))

        var sample: PresentationCadenceWindow? = null
        for (n in 1..32) {
            sample = tracker.onPresented(
                3_500L + n * 16L,
                decodedSequence = 2L + n
            ) ?: sample
        }

        val resumed = checkNotNull(sample)
        assertTrue("New motion should report healthy glass FPS", resumed.fps in 55.0..65.0)
        assertEquals(16, resumed.maxGapMs)
        assertEquals(512, resumed.intervalMs)
    }

    @Test fun decodedFramesArrivingDuringRendererStallPreserveTrueGap() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000L, decodedSequence = 1L))

        // EGL did not swap, but decoder callbacks kept arriving. The stall
        // must remain visible to the host adaptation and renderer watchdog.
        val stalled = checkNotNull(
            tracker.onPresented(3_000L, decodedSequence = 100L)
        )
        assertEquals(2_000, stalled.intervalMs)
        assertEquals(2_000, stalled.maxGapMs)
        assertEquals(1, stalled.renderedFrames)
    }

    @Test fun sparseHalfSecondSwapsStillReportTheirRealCadence() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000L, decodedSequence = 1L))
        val sparse = checkNotNull(
            tracker.onPresented(1_500L, decodedSequence = 2L)
        )
        assertEquals(2.0, sparse.fps, 0.001)
        assertEquals(500, sparse.maxGapMs)
    }

    @Test fun resetClearsDecoderIdentityAndOldPresentationClock() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000L, decodedSequence = 100L))
        tracker.reset()

        assertNull(tracker.onPresented(10_000L, decodedSequence = 1L))
        val resumed = checkNotNull(
            tracker.onPresented(10_500L, decodedSequence = 2L)
        )
        assertEquals(500, resumed.intervalMs)
        assertEquals(500, resumed.maxGapMs)
    }

    @Test fun oneFrameDecodedEarlyButRenderedLateIsNotMisclassifiedAsIdle() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000L, decodedSequence = 1L, lastDecodedAtMs = 995L))

        // The decoder delivered one frame at 1.1 s; EGL cannot silently
        // treat its later 3.0 s swap as proof of a quiet producer.
        val stalled = checkNotNull(
            tracker.onPresented(3_000L, decodedSequence = 2L, lastDecodedAtMs = 1_100L)
        )
        assertEquals(2_000, stalled.intervalMs)
        assertEquals(2_000, stalled.maxGapMs)
        assertEquals(1, stalled.renderedFrames)
    }

    @Test fun genuinelyLateSingleDecoderFrameStillReanchorsIdleToMotion() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000L, decodedSequence = 1L, lastDecodedAtMs = 995L))
        assertNull(
            tracker.onPresented(3_500L, decodedSequence = 2L, lastDecodedAtMs = 3_480L)
        )
        val resumed = checkNotNull(
            tracker.onPresented(4_000L, decodedSequence = 3L, lastDecodedAtMs = 3_995L)
        )
        assertEquals(500, resumed.maxGapMs)
    }

    @Test fun missingOrInvalidArrivalTimeKeepsCompatibleCountOnlyBehavior() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000L, decodedSequence = 1L))
        assertNull(tracker.onPresented(3_000L, decodedSequence = 2L))
        assertNull(
            tracker.onPresented(5_000L, decodedSequence = 3L, lastDecodedAtMs = 5_001L)
        )
        assertNull(
            tracker.onPresented(7_000L, decodedSequence = 3L, lastDecodedAtMs = 1_000L)
        )
    }

    @Test fun unspecifiedDecoderEvidenceKeepsExistingCadenceSemantics() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000L))
        val sample = checkNotNull(tracker.onPresented(3_000L))
        assertEquals(2_000, sample.maxGapMs)
    }
}
