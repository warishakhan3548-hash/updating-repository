package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BweDemandAwareClarityTest {
    private val profile =
        CaptureProfile(
            displayWidthPx = 720,
            displayHeightPx = 1600,
            captureWidthPx = 720,
            captureHeightPx = 1600,
            fps = 30,
            maxVideoBitrateBps = 10_000_000,
            tier = CaptureTier.STANDARD,
            motionFps = 60
        )

    private fun sender(
        fps: Int,
        bitrateBps: Long,
        availableOutgoingBitrateBps: Double
    ): VideoHealthSnapshot =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 0,
            frames = 0,
            framesSecondary = 0,
            packets = 0,
            packetsLost = 0,
            frameWidth = 720,
            frameHeight = 1600,
            qualityLimitationReason = "none",
            roundTripTimeMs = 80,
            packetLossRatio = 0.0,
            codecImplementation = "c2.qti.avc.encoder",
            recent =
                VideoHealthWindow(
                    intervalMs = 1_000,
                    frames = fps,
                    processingMs = 5.0,
                    jitterMs = null,
                    dropped = null,
                    freezes = null,
                    bitrateBps = bitrateBps,
                    sendQueueMs = 5.0
                ),
            availableOutgoingBitrateBps = availableOutgoingBitrateBps
        )

    private fun receiver(fps: Int): VideoHealthWindow =
        VideoHealthWindow(
            intervalMs = 1_000,
            frames = fps,
            processingMs = 5.0,
            jitterMs = 5.0,
            dropped = 0,
            freezes = 0,
            presentationIntervalMs = 1_000,
            presentedFrames = fps,
            maxRenderGapMs = 34
        )

    private fun nativeBudget(): MotionVideoBudget =
        MotionVideoBudget().apply {
            assertTrue(
                primeForMotion(
                    profile = profile,
                    nowMs = 0L,
                    warmStartEvidence =
                        sender(
                            fps = 1,
                            bitrateBps = 40_000,
                            availableOutgoingBitrateBps = 4_500_000.0
                        ),
                    targetFps = 30
                )
            )
            assertEquals(720, shortEdge)
        }

    private fun committedFloorBudget(): MotionVideoBudget =
        MotionVideoBudget().apply {
            val collapse =
                sender(
                    fps = 6,
                    bitrateBps = 450_000,
                    availableOutgoingBitrateBps = 600_000.0
                ).copy(
                    codecImplementation = "libvpx",
                    recent =
                        sender(
                            fps = 6,
                            bitrateBps = 450_000,
                            availableOutgoingBitrateBps = 600_000.0
                        ).recent!!.copy(
                            processingMs = 53.0,
                            sendQueueMs = 585.0
                        )
                )

            assertTrue(
                observe(
                    collapse,
                    null,
                    30.0,
                    true,
                    30,
                    1_000L
                )
            )
            assertEquals(540, shortEdge)
            assertTrue(
                observe(
                    collapse,
                    null,
                    30.0,
                    true,
                    30,
                    4_000L
                )
            )
            assertEquals(360, shortEdge)
            val applied = apply(profile, true)
            assertEquals(
                360,
                minOf(applied.captureWidthPx, applied.captureHeightPx)
            )
        }

    @Test
    fun lowDemandMovingUiDoesNotSpendCadenceForNominalBweShortfall() {
        val budget = nativeBudget()
        val cheapMovingUi =
            sender(
                fps = 60,
                bitrateBps = 700_000,
                availableOutgoingBitrateBps = 4_200_000.0
            )

        assertNull(
            budget.clarityPreservingCadenceCeiling(
                profile = profile,
                outbound = cheapMovingUi,
                receiver = receiver(60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                interactionActive = true
            )
        )
        assertEquals(720, budget.shortEdge)
    }

    @Test
    fun lowDemandMovingUiDoesNotSpendPixelsForNominalBweShortfall() {
        val budget = nativeBudget()
        val cheapMovingUi =
            sender(
                fps = 30,
                bitrateBps = 300_000,
                availableOutgoingBitrateBps = 2_000_000.0
            )

        repeat(4) { index ->
            assertFalse(
                budget.observe(
                    outbound = cheapMovingUi,
                    receiver = receiver(30),
                    sourceFps = 30.0,
                    motionActive = true,
                    targetFps = 30,
                    nowMs = 4_000L + index * 1_000L,
                    interactionActive = true
                )
            )
        }

        assertEquals(720, budget.shortEdge)
    }

    @Test
    fun moderateRealDemandDoesNotBlurBecauseNominalTableIsHigher() {
        val budget = nativeBudget()
        val healthyUi =
            sender(
                fps = 30,
                bitrateBps = 1_400_000,
                availableOutgoingBitrateBps = 2_000_000.0
            )

        // 70% measured path use leaves substantial real headroom even though
        // the old fixed 720p@30 model expected ~3.2 Mbps and would predict a
        // false shortage. Keep native pixels and let GCC own the actual rate.
        repeat(4) { index ->
            assertFalse(
                budget.observe(
                    outbound = healthyUi,
                    receiver = receiver(30),
                    sourceFps = 30.0,
                    motionActive = true,
                    targetFps = 30,
                    nowMs = 4_000L + index * 1_000L,
                    interactionActive = true
                )
            )
        }

        assertEquals(720, budget.shortEdge)
    }

    @Test
    fun highCadenceReliefUsesMeasuredDemandInsteadOfNominalBitrateTable() {
        val budget = nativeBudget()
        val complexUi =
            sender(
                fps = 60,
                bitrateBps = 4_500_000,
                availableOutgoingBitrateBps = 5_000_000.0
            )

        // 90% utilization needs headroom, but measured demand says a modest
        // 60 -> ~52 fps trim is enough. The fixed nominal table would cut much
        // harder even though the same pixels can remain readable.
        assertEquals(
            52,
            budget.clarityPreservingCadenceCeiling(
                profile = profile,
                outbound = complexUi,
                receiver = receiver(60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                interactionActive = true
            )
        )
        assertEquals(720, budget.shortEdge)
    }

    @Test
    fun healthyNativeMovingWindowCancelsSpeculativeWarmStartWithoutResize() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)
        assertEquals(profile, budget.apply(profile, true))

        val provenNative =
            sender(
                fps = 30,
                bitrateBps = 900_000,
                availableOutgoingBitrateBps = 4_000_000.0
            )

        assertTrue(
            budget.observe(
                outbound = provenNative,
                receiver = receiver(30),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_000L,
                interactionActive = true,
                allowResolutionRecovery = false
            )
        )

        // The source was already native; validation must clear only the
        // speculative control rung, never pay a 720 -> 540 -> 720 resize cycle.
        assertEquals(720, budget.shortEdge)
        assertEquals(profile, budget.apply(profile, true))
    }

    @Test
    fun cheapContentRecoversReadabilityFromCommittedDowngradeUsingRealDemand() {
        val budget = MotionVideoBudget()
        val collapse =
            sender(
                fps = 6,
                bitrateBps = 450_000,
                availableOutgoingBitrateBps = 600_000.0
            ).copy(
                codecImplementation = "libvpx",
                recent =
                    sender(
                        fps = 6,
                        bitrateBps = 450_000,
                        availableOutgoingBitrateBps = 600_000.0
                    ).recent!!.copy(
                        processingMs = 53.0,
                        sendQueueMs = 585.0
                    )
            )

        assertTrue(
            budget.observe(
                collapse,
                null,
                30.0,
                true,
                30,
                1_000L
            )
        )
        assertEquals(540, budget.shortEdge)
        assertTrue(
            budget.observe(
                collapse,
                null,
                30.0,
                true,
                30,
                4_000L
            )
        )
        assertEquals(360, budget.shortEdge)

        val recoveredCheapUi =
            sender(
                fps = 30,
                bitrateBps = 300_000,
                availableOutgoingBitrateBps = 1_200_000.0
            )

        repeat(2) { index ->
            assertFalse(
                budget.observe(
                    recoveredCheapUi,
                    receiver(30),
                    30.0,
                    true,
                    30,
                    5_000L + index * 1_000L
                )
            )
        }
        assertTrue(
            budget.observe(
                recoveredCheapUi,
                receiver(30),
                30.0,
                true,
                30,
                7_000L
            )
        )
        assertEquals(540, budget.shortEdge)
    }

    @Test
    fun terminal360TradesCadenceInsteadOfPixelsWhenMeasuredBweIsSaturated() {
        val budget = committedFloorBudget()
        val saturatedAtThirty =
            sender(
                fps = 30,
                bitrateBps = 630_000,
                availableOutgoingBitrateBps = 700_000.0
            )

        // 630/700 = 90% utilization. Preserve a 22% burst reserve:
        // floor(30 * 0.78 / 0.90) = 26. The cadence governor will quantize this
        // onto the existing low-cadence ladder (24 fps).
        assertEquals(
            26,
            budget.clarityPreservingCadenceCeiling(
                profile = profile,
                outbound = saturatedAtThirty,
                receiver = receiver(30),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                interactionActive = true
            )
        )
        assertEquals(360, budget.shortEdge)
        val applied = budget.apply(profile, true)
        assertEquals(
            360,
            minOf(applied.captureWidthPx, applied.captureHeightPx)
        )
    }

    @Test
    fun terminal360DoesNotSacrificeCadenceForCheapContent() {
        val budget = committedFloorBudget()
        val cheapAtThirty =
            sender(
                fps = 30,
                bitrateBps = 300_000,
                availableOutgoingBitrateBps = 700_000.0
            )

        assertNull(
            budget.clarityPreservingCadenceCeiling(
                profile = profile,
                outbound = cheapAtThirty,
                receiver = receiver(30),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                interactionActive = true
            )
        )
        assertEquals(360, budget.shortEdge)
    }

    @Test
    fun nonTerminalPixelsStillUseSpatialReliefBeforeSubThirtyCadence() {
        val budget = nativeBudget()
        val saturatedAtThirty =
            sender(
                fps = 30,
                bitrateBps = 630_000,
                availableOutgoingBitrateBps = 700_000.0
            )

        // Native/720 pixels still have legal 540/360 spatial relief, so the
        // clarity predictor must not spend below the ordinary 30 fps floor.
        assertNull(
            budget.clarityPreservingCadenceCeiling(
                profile = profile,
                outbound = saturatedAtThirty,
                receiver = receiver(30),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                interactionActive = true
            )
        )
        assertEquals(720, budget.shortEdge)
    }

    @Test
    fun materialPathUtilizationStillPreemptsQueueGrowth() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        val saturated =
            sender(
                fps = 60,
                bitrateBps = 630_000,
                availableOutgoingBitrateBps = 700_000.0
            )

        assertFalse(
            budget.observe(
                outbound = saturated,
                receiver = receiver(60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                outbound = saturated,
                receiver = receiver(60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        assertEquals(360, budget.shortEdge)
    }
}
