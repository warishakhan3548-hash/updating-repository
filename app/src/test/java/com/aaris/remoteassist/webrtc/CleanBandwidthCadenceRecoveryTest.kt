package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CleanBandwidthCadenceRecoveryTest {
    private fun sender(
        queueMs: Double = 2.0,
        bandwidthEstimateBps: Double? = 1_200_000.0,
        loss: Double? = 0.0,
        sourceFps: Int = 15,
        processingMs: Double = 8.0,
        rttMs: Int = 30,
        bitrateBps: Long = 200_000L
    ): VideoHealthSnapshot =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 30_000L,
            frames = sourceFps.toLong(),
            framesSecondary = sourceFps.toLong(),
            packets = 30L,
            packetsLost = 0L,
            frameWidth = 360,
            frameHeight = 800,
            qualityLimitationReason = "bandwidth",
            roundTripTimeMs = rttMs,
            packetLossRatio = loss,
            availableOutgoingBitrateBps = bandwidthEstimateBps,
            recent = VideoHealthWindow(
                intervalMs = 1_000,
                frames = sourceFps,
                processingMs = processingMs,
                jitterMs = null,
                dropped = null,
                freezes = null,
                sendQueueMs = queueMs,
                bitrateBps = bitrateBps
            )
        )

    @Test fun cleanBandwidthLabelCannotPinInteractiveFpsAtFifteen() {
        val governor = VideoCadenceGovernor(maxFps = 60, initialCap = 15)
        val clean = sender()

        assertFalse(governor.tryProbeDuringInteraction(
            outbound = clean, receiver = null,
            producerFps = 30.0, interactionActive = true, nowMs = 1_000L
        ))
        assertTrue(governor.tryProbeDuringInteraction(
            outbound = clean, receiver = null,
            producerFps = 30.0, interactionActive = true, nowMs = 1_500L
        ))
        assertEquals(24, governor.cap)
    }

    @Test fun uncorroboratedBandwidthLabelStillBlocksInteractiveProbe() {
        val variants = listOf(
            sender(queueMs = 75.0),
            sender(bandwidthEstimateBps = null),
            sender(bandwidthEstimateBps = 150_000.0),
            sender(loss = null),
            sender(loss = 0.08),
            sender(processingMs = 50.0),
            sender(rttMs = 500)
        )

        variants.forEach { snapshot ->
            val governor = VideoCadenceGovernor(maxFps = 60, initialCap = 15)
            repeat(4) { index ->
                assertFalse(governor.tryProbeDuringInteraction(
                    outbound = snapshot, receiver = null,
                    producerFps = 30.0, interactionActive = true,
                    nowMs = 1_000L + index * 500L
                ))
            }
            assertEquals(15, governor.cap)
        }
    }

    @Test fun lowProducerSupplyCannotFakeCleanBandwidthProof() {
        val governor = VideoCadenceGovernor(maxFps = 60, initialCap = 15)
        repeat(4) { index ->
            assertFalse(governor.tryProbeDuringInteraction(
                outbound = sender(), receiver = null,
                producerFps = 2.0, interactionActive = true,
                nowMs = 1_000L + index * 500L
            ))
        }
        assertEquals(15, governor.cap)
    }

    @Test fun cleanPassiveSenderCanRecoverOneRungWithoutControllerStats() {
        val governor = VideoCadenceGovernor(maxFps = 60, initialCap = 15)
        repeat(15) { index ->
            assertFalse(governor.observe(
                outbound = sender(), receiver = null, requestedFps = 15,
                nowMs = 1_000L + index * 1_000L,
                producerFps = 24.0,
                allowHighCadenceProbe = false
            ))
        }
        assertTrue(governor.observe(
            outbound = sender(), receiver = null, requestedFps = 15,
            nowMs = 16_000L, producerFps = 24.0,
            allowHighCadenceProbe = false
        ))
        assertEquals(20, governor.cap)
    }

    @Test fun passiveRecoveryRemainsBlockedWithoutKnownBandwidthHeadroom() {
        val governor = VideoCadenceGovernor(maxFps = 60, initialCap = 15)
        repeat(20) { index ->
            assertFalse(governor.observe(
                outbound = sender(bandwidthEstimateBps = null), receiver = null,
                requestedFps = 15, nowMs = 1_000L + index * 1_000L,
                producerFps = 24.0, allowHighCadenceProbe = false
            ))
        }
        assertEquals(15, governor.cap)
    }
}
