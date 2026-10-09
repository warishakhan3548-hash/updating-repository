package com.aaris.remoteassist.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RendererContinuityPolicyTest {
    private fun stalled(
        nowMs: Long = 8_000L,
        decodedAtMs: Long = 7_900L,
        presentedAtMs: Long = 4_000L,
        hadRendered: Boolean = true,
        surfaceReady: Boolean = true
    ): Boolean = RendererContinuityPolicy.shouldRecover(
        nowMs = nowMs,
        lastDecodedAtMs = decodedAtMs,
        lastPresentedAtMs = presentedAtMs,
        hadRendered = hadRendered,
        surfaceReady = surfaceReady
    )

    @Test fun freshDecodedFramesWithoutAnyEglSwapTriggerRecovery() {
        assertTrue(stalled())
        assertTrue(stalled(nowMs = 7_000L, decodedAtMs = 6_900L,
            presentedAtMs = 4_000L))
    }

    @Test fun healthyAndLowCadencePresentationDoNotTriggerRecovery() {
        assertFalse(stalled(nowMs = 8_000L, decodedAtMs = 7_900L,
            presentedAtMs = 7_200L))
        assertFalse(stalled(nowMs = 8_000L, decodedAtMs = 7_900L,
            presentedAtMs = 5_100L))
        // A new frame cannot prove missing output before the stall deadline.
    }

    @Test fun networkOrProducerStarvationIsNotMisdiagnosedAsEglFailure() {
        assertFalse(stalled(decodedAtMs = 5_000L))
        assertFalse(stalled(decodedAtMs = 3_500L))
        assertFalse(stalled(decodedAtMs = 4_000L))
    }

    @Test fun pausedSurfaceAndStartupNeverTriggerRecovery() {
        assertFalse(stalled(surfaceReady = false))
        assertFalse(stalled(hadRendered = false))
        assertFalse(stalled(presentedAtMs = 0L))
        assertFalse(stalled(decodedAtMs = 0L))
    }

    @Test fun eglFeedbackIsIgnoredAfterMainLooperBacklog() {
        assertTrue(RendererContinuityPolicy.isFreshPresentationCallback(10_000L, 10_000L))
        assertTrue(RendererContinuityPolicy.isFreshPresentationCallback(10_000L, 9_000L))
        assertFalse(RendererContinuityPolicy.isFreshPresentationCallback(10_000L, 8_999L))
        assertFalse(RendererContinuityPolicy.isFreshPresentationCallback(10_000L, 10_001L))
    }

    @Test fun startupAndInvalidPresentationClocksCannotConfirmVideo() {
        assertFalse(RendererContinuityPolicy.isFreshPresentationCallback(10_000L, 0L))
        assertFalse(RendererContinuityPolicy.isFreshPresentationCallback(0L, 0L))
        assertFalse(RendererContinuityPolicy.isFreshPresentationCallback(-1L, 100L))
        assertFalse(RendererContinuityPolicy.isFreshPresentationCallback(10_000L, -1L))
    }

    @Test fun timestampDiscontinuityCannotTriggerRecovery() {
        assertFalse(stalled(nowMs = 3_000L))
        assertFalse(stalled(nowMs = 8_000L, decodedAtMs = 8_500L))
        assertFalse(stalled(nowMs = 8_000L, presentedAtMs = 8_500L))
    }
}
