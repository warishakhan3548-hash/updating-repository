package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrossLayerLatencyBudgetTest {
    private fun outbound(
        sendQueueMs: Double,
        fps: Int = 60
    ) = VideoHealthSnapshot(
        direction = "outbound",
        codec = "video/VP8",
        bytes = 100_000,
        frames = fps.toLong(),
        framesSecondary = fps.toLong(),
        packets = (fps * 3).toLong(),
        packetsLost = 0,
        frameWidth = 1080,
        frameHeight = 2400,
        qualityLimitationReason = "none",
        roundTripTimeMs = 60,
        packetLossRatio = 0.0,
        recent = VideoHealthWindow(
            intervalMs = 1_000,
            frames = fps,
            processingMs = 5.0,
            jitterMs = null,
            dropped = null,
            freezes = null,
            sendQueueMs = sendQueueMs
        )
    )

    private fun receiver(
        jitterMs: Double,
        fps: Int = 60
    ) = VideoHealthWindow(
        intervalMs = 1_000,
        frames = fps,
        processingMs = 5.0,
        jitterMs = jitterMs,
        dropped = 0,
        freezes = 0
    )

    @Test
    fun moderateSerialQueuesGetFastFullCadenceRelief() {
        val governor = VideoCadenceGovernor(60)
        val sender = outbound(sendQueueMs = 35.0)
        val controller = receiver(jitterMs = 45.0)

        // 35 ms is below the sender's 55 ms alarm and 45 ms is below the
        // receiver's 85 ms alarm, but 80 ms of serial residence is visibly
        // stale for 60 fps remote control. At full cadence we now take one
        // immediate soft step instead of waiting another stats window.
        assertTrue(governor.observe(sender, controller, 60, 1_000))
        assertEquals(45, governor.cap)
    }

    @Test
    fun sixtyFpsUsesFastFrameRelativeResidenceRelief() {
        val governor = VideoCadenceGovernor(60)
        val sender = outbound(sendQueueMs = 25.0)
        val controller = receiver(jitterMs = 35.0)

        // Neither endpoint is individually unhealthy. Together they retain
        // about 3.6 60-Hz frame periods, which is enough to make a fresh swipe
        // visibly trail the controlled phone. One soft 60 -> 45 step drains
        // the queue while lower rungs keep conservative hysteresis.
        assertTrue(governor.observe(sender, controller, 60, 1_000))
        assertEquals(45, governor.cap)
    }

    @Test
    fun sameAbsoluteResidenceIsAcceptedAtThirtyFps() {
        val governor = VideoCadenceGovernor(60)
        val sender = outbound(sendQueueMs = 25.0, fps = 30)
        val controller = receiver(jitterMs = 35.0, fps = 30)

        repeat(4) { index ->
            assertFalse(
                governor.observe(
                    sender,
                    controller,
                    30,
                    1_000L + index * 3_000L
                )
            )
        }

        assertEquals(60, governor.cap)
    }

    @Test
    fun cleanPipelineDoesNotSacrificeSixtyFps() {
        val governor = VideoCadenceGovernor(60)
        val sender = outbound(sendQueueMs = 12.0)
        val controller = receiver(jitterMs = 18.0)

        repeat(12) { index ->
            governor.observe(
                sender,
                controller,
                60,
                1_000L + index * 1_000L
            )
        }

        assertEquals(60, governor.cap)
    }

    @Test
    fun severeCombinedResidenceTakesStrongReliefEvenIfEachQueueIsBelowSevereLimit() {
        val governor = VideoCadenceGovernor(60)
        val sender = outbound(sendQueueMs = 120.0)
        val controller = receiver(jitterMs = 110.0)

        assertTrue(governor.observe(sender, controller, 60, 1_000))
        assertEquals(30, governor.cap)
    }

    @Test
    fun missingSenderResidenceDoesNotTightenReceiverJitterThreshold() {
        val governor = VideoCadenceGovernor(60)
        val sender = outbound(sendQueueMs = 10.0).let { snapshot ->
            snapshot.copy(
                recent = checkNotNull(snapshot.recent).copy(sendQueueMs = null)
            )
        }
        val controller = receiver(jitterMs = 80.0)

        repeat(4) { index ->
            assertFalse(
                governor.observe(
                    sender,
                    controller,
                    60,
                    1_000L + index * 3_000L
                )
            )
        }
        assertEquals(60, governor.cap)
    }
}
