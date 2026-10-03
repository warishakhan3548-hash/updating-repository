package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InteractiveVideoPolicyTest {
    @Test
    fun idleStrongTiersPreserveResolution() {
        listOf(CaptureTier.STANDARD, CaptureTier.HIGH).forEach { tier ->
            val policy = InteractiveVideoPolicy.forState(tier, false)
            assertTrue(policy.preserveResolution)
            assertFalse(policy.motionPriority)
        }
    }

    @Test
    fun everyActiveTierPrioritizesFreshFrames() {
        CaptureTier.entries.forEach { tier ->
            val policy = InteractiveVideoPolicy.forState(tier, true)
            assertFalse(policy.preserveResolution)
            assertTrue(policy.motionPriority)
        }
    }

    @Test
    fun idleConstrainedTiersStayBalanced() {
        listOf(CaptureTier.LOW, CaptureTier.BALANCED).forEach { tier ->
            val policy = InteractiveVideoPolicy.forState(tier, false)
            assertFalse(policy.preserveResolution)
            assertFalse(policy.motionPriority)
        }
    }
}
