package com.aaris.remoteassist.capture

import org.junit.Assert.*
import org.junit.Test

class CaptureActivityTrackerTest {
    @Test fun countsProducerFramesButIgnoresForcedStaticDuplicates() {
        val tracker = CaptureActivityTracker()
        assertNull(tracker.sampleFps(1000))
        repeat(30) { tracker.onFrame((it + 1).toLong()) }
        assertEquals(30.0, tracker.sampleFps(2000)!!, 0.01)
        repeat(60) { tracker.onFrame(30) }
        assertEquals(0.0, tracker.sampleFps(3000)!!, 0.01)
    }
    @Test fun invalidSamplingGapsResetWithoutInventingMotion() {
        val tracker = CaptureActivityTracker()
        tracker.sampleFps(1000)
        tracker.onFrame(1)
        assertNull(tracker.sampleFps(1100))
        assertEquals(1.0, tracker.sampleFps(2000)!!, 0.01)
        tracker.onFrame(2)
        assertNull(tracker.sampleFps(10000))
        assertEquals(0.0, tracker.sampleFps(11000)!!, 0.01)
    }

    @Test fun sourceMotionPulseArrivesBeforeStatsAndIsThrottled() {
        val tracker = CaptureActivityTracker()
        var timestamp = 1_000_000_000L

        assertFalse(tracker.onFrame(timestamp))
        timestamp += 40_000_000L
        assertFalse(tracker.onFrame(timestamp))
        timestamp += 40_000_000L
        assertTrue(tracker.onFrame(timestamp))

        // Forced/static duplicates never refresh motion.
        assertFalse(tracker.onFrame(timestamp))
        assertFalse(tracker.onFrame(timestamp))

        // A sustained 8+ Hz source may refresh the motion tail, but the
        // capture thread emits at most one pulse every 750 ms.
        repeat(6) {
            timestamp += 120_000_000L
            assertFalse(tracker.onFrame(timestamp))
        }
        timestamp += 120_000_000L
        assertTrue(tracker.onFrame(timestamp))
    }

    @Test fun cadenceWindowExposesProducerStallThatAverageFpsCannotExplain() {
        val tracker = CaptureActivityTracker()
        assertNull(tracker.sample(1_000))

        var timestamp = 1_000_000_000L
        tracker.onFrame(timestamp)
        timestamp += 50_000_000L
        tracker.onFrame(timestamp)
        timestamp += 250_000_000L
        tracker.onFrame(timestamp)

        // Forced refreshes reuse the same texture timestamp and must not inflate
        // either the producer FPS or the inter-frame gap.
        repeat(5) {
            tracker.onFrame(timestamp)
        }

        val sample = checkNotNull(tracker.sample(2_000))
        assertEquals(3.0, sample.fps, 0.01)
        assertEquals(250.0, checkNotNull(sample.maxGapMs), 0.01)
        assertEquals(3, sample.frames)
    }


    @Test fun firstFrameAfterIdleDoesNotReportTheIdleIntervalAsJitter() {
        val tracker = CaptureActivityTracker()
        assertNull(tracker.sample(1_000))

        var timestamp = 1_000_000_000L
        tracker.onFrame(timestamp)
        val first = checkNotNull(tracker.sample(2_000))
        assertNull(first.maxGapMs)

        timestamp += 5_000_000_000L
        tracker.onFrame(timestamp)
        timestamp += 40_000_000L
        tracker.onFrame(timestamp)

        val resumed = checkNotNull(tracker.sample(3_000))
        assertEquals(40.0, checkNotNull(resumed.maxGapMs), 0.01)
    }

}
