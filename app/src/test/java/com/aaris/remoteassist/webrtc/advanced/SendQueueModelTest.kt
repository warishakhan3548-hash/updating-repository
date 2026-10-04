package com.aaris.remoteassist.webrtc.advanced

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SendQueueModelTest {
    @Test
    fun vbvDelayMatchesLeakyBucketMath() {
        val model = LeakyBucketSendModel()
        val t0 = 1_000_000_000L
        model.setTargetBps(t0, 100_000L)

        // 20 kbit at 100 kbps = 200 ms predicted drain time.
        val delay = model.onFrameEncoded(t0, 2_500)
        assertEquals(200.0, delay!!, 0.001)

        // 150 ms later, 5 kbit remain. Adding another 20 kbit gives 250 ms.
        val second = model.onFrameEncoded(t0 + 150_000_000L, 2_500)
        assertEquals(250.0, second!!, 0.001)
    }

    @Test
    fun noQueueEstimateUntilRealRateObserved() {
        val model = LeakyBucketSendModel()
        assertNull(model.queueDelayMs(1_000_000L))
        assertNull(model.onFrameEncoded(1_000_000L, 10_000))
    }

    @Test
    fun gateUsesHysteresisAndStarvationEscape() {
        val gate = BoundedStalenessGate(
            engageMs = 90.0,
            releaseMs = 45.0,
            maxStarveMs = 250L
        )

        assertTrue(gate.admit(100L, 20.0))
        assertFalse(gate.admit(150L, 100.0))
        assertFalse(gate.admit(200L, 70.0))
        assertTrue(gate.admit(350L, 70.0)) // starvation escape
        assertTrue(gate.admit(400L, 40.0)) // release threshold
    }
}
