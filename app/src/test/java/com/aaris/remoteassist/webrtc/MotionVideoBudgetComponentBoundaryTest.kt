package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MotionVideoBudgetComponentBoundaryTest {
    private val profile =
        CaptureProfile(720, 1600, 720, 1600, 30, 10_000_000, CaptureTier.STANDARD, 60)

    private fun sender(implementation: String?) =
        VideoHealthSnapshot(
            "outbound", "video/H264", 0, 0, 0, 0, 0, 720, 1600,
            "none", 100, 0.0,
            codecImplementation = implementation,
            streamId = "screen-stream",
            recent = VideoHealthWindow(
                1000, 20, 35.0, null, null, null, sendQueueMs = 5.0
            )
        )

    private fun nativeBudget() = MotionVideoBudget().apply {
        primeForMotion(
            profile,
            0L,
            sender("c2.vendor.encoder-a").copy(
                availableOutgoingBitrateBps = 4_500_000.0,
                recent = VideoHealthWindow(
                    1000, 1, 5.0, null, null, null, sendQueueMs = 5.0
                )
            )
        )
        assertEquals(720, apply(profile, true).captureWidthPx)
    }

    @Test fun hardwareReplacementRequiresItsOwnConsecutivePressureWindows() {
        val budget = nativeBudget()
        assertFalse(budget.observe(sender("c2.vendor.encoder-a"), null, 30.0, true, 30, 4_000L, true))

        // The RTP identity and MIME can survive a MediaCodec replacement.
        // One pressure window from each component is not consecutive proof.
        assertFalse(budget.observe(sender("c2.vendor.encoder-b"), null, 30.0, true, 30, 5_000L, true))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)

        assertTrue(budget.observe(sender("c2.vendor.encoder-b"), null, 30.0, true, 30, 6_000L, true))
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun incompleteAndCadenceOnlyBoundariesAreAdmittedBeforeSpatialObservation() {
        for (hasCompletedWindow in listOf(false, true)) {
            val budget = nativeBudget()
            assertFalse(budget.observe(sender("encoder-a"), null, 30.0, true, 30, 4_000L, true))

            // The host may return early or spend the replacement's sample on
            // cadence. Even a switch back to encoder-a must discard its vote.
            val replacement = sender("encoder-b")
            budget.onSenderEvidence(
                if (hasCompletedWindow) replacement else replacement.copy(recent = null)
            )
            assertFalse(budget.observe(sender("encoder-a"), null, 30.0, true, 30, 5_000L, true))
            assertEquals(720, budget.apply(profile, true).captureWidthPx)
            assertTrue(budget.observe(sender("encoder-a"), null, 30.0, true, 30, 6_000L, true))
        }
    }

    @Test fun missingAndNormalizedLabelsDoNotInventAReplacement() {
        for (label in listOf(null, " ", " C2.VENDOR.ENCODER-A ")) {
            val budget = nativeBudget()
            assertFalse(budget.observe(sender("c2.vendor.encoder-a"), null, 30.0, true, 30, 4_000L, true))
            assertTrue(budget.observe(sender(label), null, 30.0, true, 30, 5_000L, true))
            assertEquals(540, budget.apply(profile, true).captureWidthPx)
        }
    }

    @Test fun missingLabelCannotHideTheNextKnownReplacement() {
        val budget = nativeBudget()
        assertFalse(budget.observe(sender("encoder-a"), null, 30.0, true, 30, 4_000L, true))
        budget.onSenderEvidence(sender(" ").copy(recent = null))
        assertFalse(budget.observe(sender("encoder-b"), null, 30.0, true, 30, 5_000L, true))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun firstConcreteLabelDoesNotEraseCompatibleUnknownComponentEvidence() {
        val budget = nativeBudget()
        assertFalse(budget.observe(sender(null), null, 30.0, true, 30, 4_000L, true))
        assertTrue(budget.observe(sender("encoder-a"), null, 30.0, true, 30, 5_000L, true))
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun aNewStreamCannotInheritThePreviousStreamsSoftwareLabel() {
        val budget = nativeBudget()
        budget.onSenderEvidence(sender("libvpx").copy(recent = null))
        val newStream = sender(null).copy(streamId = "new-stream")
        budget.onSenderEvidence(newStream.copy(recent = null))
        assertFalse(budget.observe(newStream, null, 30.0, true, 30, 4_000L, true))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun softwareFallbackStillWaitsForACompletedWindowBeforeCommittingPixels() {
        val budget = nativeBudget()
        budget.onSenderEvidence(sender(" libvpx ").copy(recent = null))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
        assertTrue(budget.observe(sender("LIBVPX"), null, 30.0, true, 30, 4_000L, true))
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun replacementCannotCompleteThePreviousComponentsResidenceSlope() {
        val budget = nativeBudget()
        fun rising(implementation: String, queueMs: Double) = sender(implementation).copy(
            recent = VideoHealthWindow(
                1000, 60, 5.0, null, null, null, sendQueueMs = queueMs
            )
        )
        assertFalse(budget.observe(rising("encoder-a", 20.0), null, 60.0, true, 60, 4_000L, true))
        assertFalse(budget.observe(rising("encoder-a", 40.0), null, 60.0, true, 60, 5_000L, true))
        assertFalse(budget.observe(rising("encoder-b", 60.0), null, 60.0, true, 60, 6_000L, true))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun committedReliefAndItsSettleTimerSurviveAComponentBoundary() {
        val budget = nativeBudget()
        assertFalse(budget.observe(sender("encoder-a"), null, 30.0, true, 30, 4_000L, true))
        assertTrue(budget.observe(sender("encoder-a"), null, 30.0, true, 30, 5_000L, true))
        budget.onSenderEvidence(sender("encoder-b").copy(recent = null))
        assertEquals(540, budget.apply(profile, true).captureWidthPx)

        assertFalse(budget.observe(sender("encoder-b"), null, 30.0, true, 30, 5_500L, true))
        assertFalse(budget.observe(sender("encoder-b"), null, 30.0, true, 30, 6_000L, true))
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
        assertTrue(budget.observe(sender("encoder-b"), null, 30.0, true, 30, 8_000L, true))
        assertEquals(360, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun recoveryVotesRestartOnReplacementWithoutUndoingCommittedRelief() {
        val budget = nativeBudget()
        val collapse = sender("encoder-a").copy(
            recent = VideoHealthWindow(
                1000, 6, 53.0, null, null, null, sendQueueMs = 585.0
            )
        )
        assertTrue(budget.observe(collapse, null, 30.0, true, 30, 4_000L))
        assertTrue(budget.observe(collapse, null, 30.0, true, 30, 7_000L))
        assertEquals(360, budget.apply(profile, true).captureWidthPx)

        val receiver = VideoHealthWindow(
            1000, 30, 5.0, 5.0, 0, 0,
            presentationIntervalMs = 1000, presentedFrames = 30, maxRenderGapMs = 34
        )
        fun healthy(implementation: String) = sender(implementation).copy(
            availableOutgoingBitrateBps = 5_000_000.0,
            recent = VideoHealthWindow(
                1000, 30, 5.0, null, null, null, sendQueueMs = 5.0
            )
        )
        assertFalse(budget.observe(healthy("encoder-a"), receiver, 30.0, true, 30, 8_000L))
        assertFalse(budget.observe(healthy("encoder-a"), receiver, 30.0, true, 30, 9_000L))
        assertFalse(budget.observe(healthy("encoder-b"), receiver, 30.0, true, 30, 10_000L))
        assertEquals(360, budget.apply(profile, true).captureWidthPx)
        assertFalse(budget.observe(healthy("encoder-b"), receiver, 30.0, true, 30, 11_000L))
        assertTrue(budget.observe(healthy("encoder-b"), receiver, 30.0, true, 30, 12_000L))
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
    }
}
