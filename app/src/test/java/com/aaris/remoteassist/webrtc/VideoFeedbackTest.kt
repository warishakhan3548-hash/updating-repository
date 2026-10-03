package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import org.junit.Assert.*
import org.junit.Test
import org.webrtc.RTCStats
import org.webrtc.RTCStatsReport

class VideoFeedbackTest {
    private fun snapshot(time: Long, frames: Long, total: Double, id: String = "video", dropped: Long = 100): VideoHealthSnapshot {
        val stat = RTCStats(time, "inbound-rtp", id, mapOf("kind" to "video", "bytesReceived" to frames * 1000,
            "framesReceived" to frames, "framesDecoded" to frames, "packetsReceived" to frames * 3,
            "totalDecodeTime" to total, "jitterBufferDelay" to total * 2, "jitterBufferEmittedCount" to frames,
            "framesDropped" to dropped, "freezeCount" to 20L))
        return checkNotNull(VideoHealthSnapshot.from(RTCStatsReport(time, mapOf(id to stat)), PeerRole.CONTROLLER))
    }
    @Test fun recentPressureUsesCounterDeltasInsteadOfDilutedLifetimeAverages() {
        val tracker = VideoHealthWindowTracker()
        assertNull(tracker.sample(snapshot(1_000_000, 3000, 3.0)).recent)
        val result = tracker.sample(snapshot(2_000_000, 3030, 3.9, dropped = 106))
        val recent = checkNotNull(result.recent)
        assertEquals(30.0, recent.processingMs!!, 0.001)
        assertEquals(60.0, recent.jitterMs!!, 0.001)
        assertEquals(6, recent.dropped); assertEquals(0, recent.freezes)
        assertEquals(30.0, recent.fps, 0.001); assertEquals(240_000L, recent.bitrateBps)
        assertTrue(result.processingAverageMs!! < 2)
    }
    @Test fun counterResetNewStreamMissingStatsAndLongGapDoNotInventHealth() {
        val tracker = VideoHealthWindowTracker()
        tracker.sample(snapshot(1_000_000, 300, 3.0))
        assertNull(tracker.sample(snapshot(2_000_000, 2, 0.1)).recent)
        assertNull(tracker.sample(snapshot(3_000_000, 32, 0.3, "new")).recent)
        assertNull(tracker.sample(snapshot(20_000_000, 500, 4.0, "new")).recent)
        val missing = snapshot(21_000_000, 530, 4.1, "new").copy(processingTotalSeconds = null, jitterTotalSeconds = null)
        assertNull(tracker.sample(missing).recent!!.processingMs)
    }
    private val packet = ControlPacket.VideoFeedback(42, 2, 1, 1000, 30, 8f, 30f, 1, 0)
    @Test fun boundedWirePacketRoundTripsAndRejectsTruncationNaNsAndUnknownVersion() {
        val bytes = ControlProtocol.encode(packet)
        assertEquals(46, bytes.size); assertEquals(packet, ControlProtocol.decode(bytes))
        assertNull(ControlProtocol.toRemoteCommand("session", packet, 1080, 2400))
        assertNull(ControlProtocol.decode(bytes.copyOf(bytes.size - 1)))
        assertNull(ControlProtocol.decode(bytes + byteArrayOf(0)))
        val nan = bytes.clone(); java.nio.ByteBuffer.wrap(nan).putFloat(30, Float.NaN)
        assertNull(ControlProtocol.decode(nan))
        assertNull(ControlProtocol.decode(bytes.clone().apply { this[0] = 99 }))
    }
    @Test fun feedbackRequiresCurrentLeaseGenerationAndFreshIncreasingSequence() {
        val feedback = ReceiverVideoFeedback()
        assertFalse(feedback.accept(packet, 99, 2, 0))
        assertFalse(feedback.accept(packet, 42, 3, 0))
        assertTrue(feedback.accept(packet, 42, 2, 100))
        assertFalse(feedback.accept(packet, 42, 2, 101))
        assertNotNull(feedback.consume(42, 2, 200)); assertNull(feedback.consume(42, 2, 201))
        assertTrue(feedback.accept(packet.copy(sequence = 2), 42, 2, 300))
        assertNull(feedback.consume(42, 3, 301))
        assertTrue(feedback.accept(packet.copy(sequence = 3), 42, 2, 400))
        assertNull(feedback.consume(42, 2, 3401))
    }
    private fun outbound(codecMs: Double = 5.0, reason: String = "none") =
        snapshot(2_000_000, 30, 0.15).copy(direction = "outbound", qualityLimitationReason = reason,
            roundTripTimeMs = 40, packetLossRatio = 0.0, recent = VideoHealthWindow(1000, 30, codecMs, null, null, null))
    private fun receiver(ms: Double = 5.0, dropped: Int = 0) = VideoHealthWindow(1000, 30, ms, 20.0, dropped, 0)
    @Test fun slowReceiverReducesFpsBeforeResolutionAndHealthyRecoveryIsGradual() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound().let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        assertFalse(governor.observe(sending60, receiver(25.0), 60, 1000))
        assertTrue(governor.observe(sending60, receiver(25.0), 60, 2000))
        assertEquals(30, governor.cap); assertFalse(governor.mayReduceResolution(3000))
        repeat(11) { governor.observe(outbound(), receiver(), 30, 3000L + it * 1000) }
        assertEquals(30, governor.cap)
        assertTrue(governor.observe(outbound(), receiver(), 30, 14_000)); assertEquals(60, governor.cap)
    }
    @Test fun sustainedSenderQueueResidenceReducesCadenceBeforeVisibleFreeze() {
        val governor = VideoCadenceGovernor(60)
        val queued = outbound().let {
            it.copy(recent = it.recent!!.copy(frames = 60, sendQueueMs = 70.0))
        }
        val healthyReceiver = receiver().copy(frames = 60)
        assertFalse(governor.observe(queued, healthyReceiver, 60, 1000))
        assertTrue(governor.observe(queued, healthyReceiver, 60, 2000))
        assertEquals(30, governor.cap)
    }
    @Test fun severeQueueResidenceCanDownshiftAfterOneMeasuredWindow() {
        val governor = VideoCadenceGovernor(60)
        val queued = outbound().let {
            it.copy(recent = it.recent!!.copy(frames = 60, sendQueueMs = 180.0))
        }
        assertTrue(governor.observe(queued, receiver().copy(frames = 60), 60, 1000))
        assertEquals(30, governor.cap)
    }
    @Test fun receiverJitterResidenceIsLatencyPressureEvenBeforeDropsOrFreezes() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound().let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        val delayedReceiver = receiver().copy(frames = 60, jitterMs = 100.0, dropped = 0, freezes = 0)
        assertFalse(governor.observe(sending60, delayedReceiver, 60, 1000))
        assertTrue(governor.observe(sending60, delayedReceiver, 60, 2000))
        assertEquals(30, governor.cap)
    }
    @Test fun isolatedSpikeAndQuietOrMissingFramesDoNotDriveQualityOscillation() {
        val governor = VideoCadenceGovernor(60)
        governor.observe(outbound(), receiver(40.0), 60, 1000)
        governor.observe(outbound(), receiver(), 60, 2000)
        assertEquals(60, governor.cap)
        repeat(4) { governor.observe(outbound(50.0, "cpu"), null, governor.cap, 3000L + it * 3000) }
        assertTrue(governor.cap <= 24)
        val reduced = governor.cap
        repeat(20) { governor.observe(outbound().copy(recent = VideoHealthWindow(1000, 0, null, null, null, null)), null, reduced, 20_000L + it * 1000) }
        assertEquals(reduced, governor.cap)
        assertTrue(governor.mayReduceResolution(50_000))
    }
    @Test fun olderControllerCanRecoverUsingSustainedMeasuredSenderHeadroom() {
        val governor = VideoCadenceGovernor(60)
        governor.observe(outbound(40.0), null, 60, 1000)
        governor.observe(outbound(40.0), null, 60, 2000)
        assertEquals(30, governor.cap)
        repeat(16) { governor.observe(outbound(), null, 30, 3000L + it * 1000) }
        assertEquals(60, governor.cap)
    }
    @Test fun healthyPipelinedHardwareIsNotCappedJustBecauseCodecTimeExceedsFrameInterval() {
        val governor = VideoCadenceGovernor(60)
        val sender = outbound(25.0).let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        repeat(10) { governor.observe(sender, receiver(25.0).copy(frames = 60), 60, 1000L + it * 1000) }
        assertEquals(60, governor.cap)
    }
}
