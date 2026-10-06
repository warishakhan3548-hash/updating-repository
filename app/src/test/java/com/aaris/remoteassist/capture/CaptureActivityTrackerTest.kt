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
}
