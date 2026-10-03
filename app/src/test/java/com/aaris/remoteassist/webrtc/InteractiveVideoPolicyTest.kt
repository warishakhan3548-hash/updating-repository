package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InteractiveVideoPolicyTest {
    @Test
    fun idleStrongTiersPreserveResolution() {
        listOf(
            CaptureTier.STANDARD,
            CaptureTier.HIGH
        ).forEach { tier ->
            val policy = InteractiveVideoPolicy.forState(
                tier = tier,
                interactionActive = false
            )

            assertTrue(policy.preserveResolution)
            assertFalse(policy.motionPriority)
        }
    }

    @Test
    fun activeStrongTiersPrioritizeFreshMotionFrames() {
        listOf(
            CaptureTier.STANDARD,
            CaptureTier.HIGH
        ).forEach { tier ->
            val policy = InteractiveVideoPolicy.forState(
                tier = tier,
                interactionActive = true
            )

            assertFalse(policy.preserveResolution)
            assertTrue(policy.motionPriority)
        }
    }

    @Test
    fun activeConstrainedTiersProtectFrameFreshness() {
        listOf(
            CaptureTier.LOW,
            CaptureTier.BALANCED
        ).forEach { tier ->
            val policy = InteractiveVideoPolicy.forState(
                tier = tier,
                interactionActive = true
            )

            assertFalse(policy.preserveResolution)
            assertTrue(policy.motionPriority)
        }
    }

    @Test
    fun idleConstrainedTiersStayBalanced() {
        listOf(
            CaptureTier.LOW,
            CaptureTier.BALANCED
        ).forEach { tier ->
            val policy = InteractiveVideoPolicy.forState(
                tier = tier,
                interactionActive = false
            )

            assertFalse(policy.preserveResolution)
            assertFalse(policy.motionPriority)
        }
    }

    @Test
    fun everyActiveTierUsesMotionPriority() {
        CaptureTier.entries.forEach { tier ->
            val policy = InteractiveVideoPolicy.forState(
                tier = tier,
                interactionActive = true
            )

            assertTrue(policy.motionPriority)
        }
    }
}
