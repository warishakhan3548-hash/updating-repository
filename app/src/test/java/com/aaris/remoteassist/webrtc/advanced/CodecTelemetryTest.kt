package com.aaris.remoteassist.webrtc.advanced

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CodecTelemetryTest {
    @Test
    fun sampleRingTracksRecentPercentilesAcrossWrap() {
        val ring = SampleRing(capacity = 4)
        assertNull(ring.percentile(0.95))

        ring.add(10.0)
        ring.add(20.0)
        ring.add(30.0)
        ring.add(40.0)
        assertEquals(30.0, ring.percentile(0.95)!!, 0.001)

        // Overwrite the oldest value; percentile must use the fixed recent ring,
        // not assume storage remains in chronological order after wrap.
        ring.add(100.0)
        assertEquals(40.0, ring.percentile(0.95)!!, 0.001)
        assertEquals(4, ring.count())
    }

    @Test
    fun sampleRingIgnoresNonFiniteValues() {
        val ring = SampleRing(capacity = 4)
        ring.add(Double.NaN)
        ring.add(Double.POSITIVE_INFINITY)
        ring.add(12.0)

        assertEquals(1, ring.count())
        assertEquals(12.0, ring.percentile(0.5)!!, 0.001)
    }
}
