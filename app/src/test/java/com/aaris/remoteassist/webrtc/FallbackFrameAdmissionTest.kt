package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FallbackFrameAdmissionTest {
    @Test fun backpressureDoesNotConsumeTheFirstAvailableFrame() {
        val gate = FallbackFrameAdmission()
        assertEquals(
            FallbackFrameAdmission.Decision.BACKPRESSURED,
            gate.tryAcquire(1_000L, 90L) { false }
        )
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_001L, 90L) { true }
        )
        gate.finish()
    }

    @Test fun busyEncoderDoesNotAdvanceCooldown() {
        val gate = FallbackFrameAdmission()
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_000L, 90L) { true }
        )
        assertEquals(
            FallbackFrameAdmission.Decision.BUSY,
            gate.tryAcquire(1_200L, 90L) { true }
        )
        gate.finish()
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_201L, 90L) { true }
        )
        gate.finish()
    }

    @Test fun realAcceptedFramesAreRateLimited() {
        val gate = FallbackFrameAdmission()
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_000L, 90L) { true }
        )
        gate.finish()
        var capacityChecked = false
        assertEquals(
            FallbackFrameAdmission.Decision.THROTTLED,
            gate.tryAcquire(1_089L, 90L) {
                capacityChecked = true
                true
            }
        )
        assertFalse(capacityChecked)
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_090L, 90L) { true }
        )
        gate.finish()
    }

    @Test fun resetDoesNotBypassAnActiveFrameButUnblocksRecoveryAfterFinish() {
        val gate = FallbackFrameAdmission()
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_000L, 450L) { true }
        )
        gate.resetCooldown()
        assertEquals(
            FallbackFrameAdmission.Decision.BUSY,
            gate.tryAcquire(1_001L, 450L) { true }
        )
        gate.finish()
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_002L, 450L) { true }
        )
        gate.finish()
    }

    @Test fun failedCapacityAttemptsNeverCreateADeferredDeadline() {
        val gate = FallbackFrameAdmission()
        repeat(100) {
            assertEquals(
                FallbackFrameAdmission.Decision.BACKPRESSURED,
                gate.tryAcquire(1_000L + it, 450L) { false }
            )
        }
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_100L, 450L) { true }
        )
        gate.finish()
    }

    @Test fun backwardsMonotonicSampleDoesNotLockOutNextFrame() {
        val gate = FallbackFrameAdmission()
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(1_000L, 90L) { true }
        )
        gate.finish()
        assertEquals(
            FallbackFrameAdmission.Decision.ACCEPTED,
            gate.tryAcquire(100L, 90L) { true }
        )
        gate.finish()
        assertTrue(true)
    }
}
