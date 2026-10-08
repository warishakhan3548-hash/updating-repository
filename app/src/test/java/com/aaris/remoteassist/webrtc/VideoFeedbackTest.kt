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

    @Test fun earlyRealtimeStatsProbesAccumulateUntilValidWindow() {
        val tracker = VideoHealthWindowTracker()
        assertNull(tracker.sample(snapshot(1_000_000, 300, 3.0)).recent)
        assertNull(tracker.sample(snapshot(1_120_000, 304, 3.04)).recent)
        assertNull(tracker.sample(snapshot(1_480_000, 314, 3.14)).recent)
        val window = checkNotNull(
            tracker.sample(snapshot(1_960_000, 329, 3.29)).recent
        )
        assertEquals(960, window.intervalMs)
        assertEquals(29, window.frames)
        assertEquals(29 * 1000.0 / 960.0, window.fps, 0.001)
    }

    @Test fun earlyCounterResetReseedsWithoutStaleDeltas() {
        val tracker = VideoHealthWindowTracker()
        assertNull(tracker.sample(snapshot(1_000_000, 300, 3.0)).recent)
        assertNull(tracker.sample(snapshot(1_200_000, 2, 0.02)).recent)
        val window = checkNotNull(
            tracker.sample(snapshot(1_800_000, 20, 0.2)).recent
        )
        assertEquals(600, window.intervalMs)
        assertEquals(18, window.frames)
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

    @Test fun decoderFeedbackRetainsMultipleWindowsUntilHostConsumes() {
        val receiver = ReceiverVideoFeedback()
        val first = ControlPacket.VideoFeedback(42, 2, 1, 500, 10, 20f, 150f, 5, 1)
        val second = ControlPacket.VideoFeedback(42, 2, 2, 500, 30, 5f, 10f, 0, 0)
        assertTrue(receiver.accept(first, 42, 2, 100))
        assertTrue(receiver.accept(second, 42, 2, 620))
        val combined = checkNotNull(receiver.consume(42, 2, 700))
        assertEquals(1000, combined.intervalMs)
        assertEquals(40, combined.frames)
        assertEquals(8.75, combined.processingMs!!, 0.001)
        assertEquals(45.0, combined.jitterMs!!, 0.001)
        assertEquals(5, combined.dropped)
        assertEquals(1, combined.freezes)
    }
    @Test fun lostDecoderReportCannotFabricateHealthyContinuousFps() {
        val feedback = ReceiverVideoFeedback()
        val beforeDrop = ControlPacket.VideoFeedback(
            42, 2, 1, 500, 30, 6f, 12f, 0, 0
        )
        val afterDrop = ControlPacket.VideoFeedback(
            42, 2, 2, 500, 3, 18f, 160f, 4, 1
        )

        assertTrue(feedback.accept(beforeDrop, 42, 2, 100))
        // This 1.6 s arrival gap cannot be described by the second 500 ms
        // measurement plus ordinary callback jitter. The missing time was
        // never observed, so do not report (30 + 3) / 1 s = 33 fps.
        assertTrue(feedback.accept(afterDrop, 42, 2, 1_700))

        val recent = checkNotNull(feedback.consume(42, 2, 1_750))
        assertEquals(500, recent.intervalMs)
        assertEquals(3, recent.frames)
        assertEquals(6.0, recent.fps, 0.001)
        assertEquals(18.0, recent.processingMs!!, 0.001)
        assertEquals(160.0, recent.jitterMs!!, 0.001)
        assertEquals(4, recent.dropped)
        assertEquals(1, recent.freezes)
    }

    @Test fun delayedButContiguousDecoderReportsStillAggregate() {
        val feedback = ReceiverVideoFeedback()
        val first = ControlPacket.VideoFeedback(
            42, 2, 1, 500, 15, 20f, 50f, 2, 1
        )
        val second = ControlPacket.VideoFeedback(
            42, 2, 2, 500, 14, 10f, 20f, 1, 0
        )

        assertTrue(feedback.accept(first, 42, 2, 100))
        // A 900 ms callback gap is tolerated for one 500 ms measurement.
        assertTrue(feedback.accept(second, 42, 2, 1_000))
        val recent = checkNotNull(feedback.consume(42, 2, 1_050))
        assertEquals(1_000, recent.intervalMs)
        assertEquals(29, recent.frames)
        assertEquals(29.0, recent.fps, 0.001)
        assertEquals(3, recent.dropped)
        assertEquals(1, recent.freezes)
    }

    @Test fun fastSenderProbeCannotDiscardUnpairedDecoderAndGlassEvidence() {
        val feedback = ReceiverVideoFeedback()
        val first = ControlPacket.VideoFeedback(42, 2, 1, 500, 10, 20f, 150f, 5, 1)
        val second = ControlPacket.VideoFeedback(42, 2, 2, 500, 30, 5f, 10f, 0, 0)
        val glass = ControlPacket.PresentationFeedback(42, 2, 10, 500, 15, 130)

        assertTrue(feedback.accept(first, 42, 2, 100))
        assertTrue(feedback.accept(glass, 42, 2, 150))

        // The one-shot 120 ms reconfigure kick is not a complete sender window.
        // It must neither drain decoder freezes nor consume the glass sample.
        assertNull(
            feedback.consume(
                42, 2, 220, senderWindowReady = false
            )
        )
        assertTrue(feedback.accept(second, 42, 2, 620))

        val paired = checkNotNull(
            feedback.consume(
                42, 2, 700, senderWindowReady = true
            )
        )
        assertEquals(1000, paired.intervalMs)
        assertEquals(40, paired.frames)
        assertEquals(5, paired.dropped)
        assertEquals(1, paired.freezes)
        assertEquals(130, paired.maxRenderGapMs)
        assertEquals(30.0, paired.presentedFps!!, 0.001)
        assertTrue(paired.presentationSampleFresh)
        assertEquals(10L, paired.presentationSampleSequence)
    }

    @Test fun incompleteSenderSamplesCannotKeepExpiredReceiverEvidenceAlive() {
        val feedback = ReceiverVideoFeedback()
        assertTrue(feedback.accept(packet, 42, 2, 100))
        assertNull(feedback.consume(42, 2, 200, senderWindowReady = false))
        // Holding unpaired evidence does not override its existing 3 s age cap.
        assertNull(feedback.consume(42, 2, 3_101, senderWindowReady = true))
    }

    @Test fun decoderFeedbackDoesNotBlendOldOrOversizedSamples() {
        val feedback = ReceiverVideoFeedback()
        val first = ControlPacket.VideoFeedback(42, 2, 1, 4000, 200, 7f, 30f, 2, 1)
        val second = ControlPacket.VideoFeedback(42, 2, 2, 3000, 100, 6f, 20f, 0, 0)
        assertTrue(feedback.accept(first, 42, 2, 100))
        assertTrue(feedback.accept(second, 42, 2, 200))
        val bounded = checkNotNull(feedback.consume(42, 2, 300))
        assertEquals(3000, bounded.intervalMs)
        assertEquals(100, bounded.frames)
        assertEquals(0, bounded.freezes)
        assertTrue(feedback.accept(first.copy(sequence = 3), 42, 2, 400))
        assertTrue(feedback.accept(second.copy(sequence = 4), 42, 2, 3501))
        val recent = checkNotNull(feedback.consume(42, 2, 3600))
        assertEquals(3000, recent.intervalMs)
        assertEquals(100, recent.frames)
    }

    @Test fun decoderFeedbackDoesNotInventUnknownSamples() {
        val feedback = ReceiverVideoFeedback()
        val first = ControlPacket.VideoFeedback(42, 2, 1, 500, 20, 9f, 50f, 3, 1)
        val unknown = ControlPacket.VideoFeedback(42, 2, 2, 500, 10, -1f, -1f, -1, -1)
        assertTrue(feedback.accept(first, 42, 2, 100))
        assertTrue(feedback.accept(unknown, 42, 2, 650))
        val sample = checkNotNull(feedback.consume(42, 2, 700))
        assertEquals(1000, sample.intervalMs)
        assertEquals(30, sample.frames)
        assertNull(sample.processingMs)
        assertNull(sample.jitterMs)
        assertNull(sample.dropped)
        assertNull(sample.freezes)
    }
    @Test fun presentationCadenceSurvivesStatsPhaseSkewWithoutBecomingNewProofTwice() {
        val feedback = ReceiverVideoFeedback()
        val presentation =
            ControlPacket.PresentationFeedback(
                leaseSecret = 42,
                generation = 2,
                sequence = 10,
                intervalMs = 500,
                renderedFrames = 15,
                maxGapMs = 36
            )
        assertTrue(feedback.accept(presentation, 42, 2, 1_000))

        val first = checkNotNull(feedback.consume(42, 2, 1_050))
        assertEquals(30.0, first.presentedFps!!, 0.001)
        assertEquals(10L, first.presentationSampleSequence)
        assertEquals(50, first.presentationSampleAgeMs)
        assertTrue(first.presentationSampleFresh)

        // The independent stats loop may tick again before the next 500 ms EGL
        // window closes. Keep the same cadence visible, but mark it held so it
        // cannot be counted as a second adaptation vote.
        val held = checkNotNull(feedback.consume(42, 2, 1_500))
        assertEquals(30.0, held.presentedFps!!, 0.001)
        assertEquals(10L, held.presentationSampleSequence)
        assertEquals(500, held.presentationSampleAgeMs)
        assertFalse(held.presentationSampleFresh)

        // Retention is bounded; liveness heartbeat state may remain, but stale
        // cadence itself disappears.
        val expired = checkNotNull(feedback.consume(42, 2, 2_501))
        assertNull(expired.presentedFps)
        assertNull(expired.presentationSampleSequence)

        val next = presentation.copy(sequence = 11)
        assertTrue(feedback.accept(next, 42, 2, 2_600))
        val freshAgain = checkNotNull(feedback.consume(42, 2, 2_650))
        assertEquals(11L, freshAgain.presentationSampleSequence)
        assertTrue(freshAgain.presentationSampleFresh)
    }

    @Test fun retainedBadPresentationCannotCascadeMultipleCadenceDrops() {
        val governor = VideoCadenceGovernor(60, 60)
        val badFresh =
            receiver().copy(
                frames = 60,
                presentationIntervalMs = 500,
                presentedFrames = 24,
                maxRenderGapMs = 50,
                presentationAgeMs = 50,
                presentationSampleSequence = 7,
                presentationSampleAgeMs = 50,
                presentationSampleFresh = true
            )
        val sender60 =
            outbound().let {
                it.copy(recent = it.recent!!.copy(frames = 60))
            }

        assertFalse(
            governor.observe(
                sender60,
                badFresh,
                60,
                1_000L,
                producerFps = 60.0
            )
        )
        assertEquals(60, governor.cap)

        val secondFresh =
            badFresh.copy(
                presentationSampleSequence = 8
            )
        assertTrue(
            governor.observe(
                sender60,
                secondFresh,
                60,
                1_500L,
                producerFps = 60.0
            )
        )
        assertEquals(58, governor.cap)

        val sameHeldSample =
            secondFresh.copy(
                presentationSampleAgeMs = 550,
                presentationSampleFresh = false
            )
        assertFalse(
            governor.observe(
                sender60,
                sameHeldSample,
                58,
                2_000L,
                producerFps = 60.0
            )
        )
        assertEquals(58, governor.cap)
    }

    @Test fun workingDecoderEvidenceSurvivesConsumptionButExpiresAndCannotCrossLeases() {
        val feedback = ReceiverVideoFeedback()
        assertFalse(feedback.hasRecentDecodedFrames(42, 2, 100))
        assertTrue(feedback.accept(packet, 42, 2, 100))
        assertNotNull(feedback.consume(42, 2, 200))
        assertTrue(feedback.hasRecentDecodedFrames(42, 2, 300))
        assertFalse(feedback.hasRecentDecodedFrames(99, 2, 300))
        assertFalse(feedback.hasRecentDecodedFrames(42, 3, 300))
        assertFalse(feedback.hasRecentDecodedFrames(42, 2, 99))
        // Zero decoded frames and rejected/replayed reports cannot refresh proof.
        assertTrue(feedback.accept(packet.copy(sequence = 2, decodedFrames = 0), 42, 2, 2_900))
        assertFalse(feedback.accept(packet, 42, 2, 3_000))
        assertTrue(feedback.hasRecentDecodedFrames(42, 2, 3_100))
        assertFalse(feedback.hasRecentDecodedFrames(42, 2, 3_101))
        assertTrue(feedback.accept(packet.copy(generation = 3, decodedFrames = 0), 42, 3, 3_200))
        assertFalse(feedback.hasRecentDecodedFrames(42, 3, 3_200))
    }
    private fun outbound(codecMs: Double = 5.0, reason: String = "none") =
        snapshot(2_000_000, 30, 0.15).copy(direction = "outbound", qualityLimitationReason = reason,
            roundTripTimeMs = 40, packetLossRatio = 0.0, recent = VideoHealthWindow(1000, 30, codecMs, null, null, null))
    private fun receiver(ms: Double = 5.0, dropped: Int = 0) = VideoHealthWindow(1000, 30, ms, 20.0, dropped, 0)
    @Test fun slowReceiverReducesFpsAndDecoderAloneCannotAuthorizeHighCadence() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound().let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        assertFalse(governor.observe(sending60, receiver(25.0), 60, 1000))
        assertTrue(governor.observe(sending60, receiver(25.0), 60, 2000))
        assertEquals(58, governor.cap); assertFalse(governor.mayReduceResolution(3000))
        repeat(11) { governor.observe(outbound(), receiver(), 58, 3000L + it * 1000) }
        assertEquals(58, governor.cap)
        assertFalse(governor.observe(outbound(), receiver(), 58, 14_000)); assertEquals(58, governor.cap)
    }
    @Test fun measuredSenderQueueResidenceGetsFineGrainedRelief() {
        val governor = VideoCadenceGovernor(60)
        val queued = outbound().let {
            it.copy(recent = it.recent!!.copy(frames = 60, sendQueueMs = 70.0))
        }
        val healthyReceiver = receiver().copy(frames = 60)
        assertFalse(governor.observe(queued, healthyReceiver, 60, 1000))
        assertEquals(60, governor.cap)
        assertTrue(governor.observe(queued, healthyReceiver, 60, 1500))
        assertEquals(58, governor.cap)
    }
    @Test fun severeQueueResidenceCanDownshiftAfterOneMeasuredWindow() {
        val governor = VideoCadenceGovernor(60)
        val queued = outbound().let {
            it.copy(recent = it.recent!!.copy(frames = 60, sendQueueMs = 180.0))
        }
        assertTrue(governor.observe(queued, receiver().copy(frames = 60), 60, 1000))
        assertEquals(30, governor.cap)
    }
    @Test fun receiverJitterResidenceGetsFastIntermediateCadenceBeforeThirty() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound().let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        val delayedReceiver = receiver().copy(frames = 60, jitterMs = 100.0, dropped = 0, freezes = 0)
        assertFalse(governor.observe(sending60, delayedReceiver, 60, 1000))
        assertEquals(60, governor.cap)
        assertTrue(governor.observe(sending60, delayedReceiver, 60, 1500))
        assertEquals(58, governor.cap)
    }
    @Test fun cpuPressureSkipsFortyFiveBecauseEncoderNeedsStrongerRelief() {
        val governor = VideoCadenceGovernor(60)
        val cpuBound = outbound(50.0, "cpu").let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        assertFalse(governor.observe(cpuBound, receiver(), 60, 1000))
        assertTrue(governor.observe(cpuBound, receiver(), 60, 4000))
        assertEquals(30, governor.cap)
    }
    @Test fun severeControllerPresentationJankCanJumpDirectlyToSustainableCadence() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound().let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        val displayBound = receiver().copy(
            frames = 60,
            presentationIntervalMs = 1000,
            presentedFrames = 22,
            maxRenderGapMs = 190
        )
        assertTrue(governor.observe(sending60, displayBound, 60, 1000))
        assertEquals(24, governor.cap)
    }

    @Test fun healthyRealPresentationDoesNotPunishPipelinedSixtyFps() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound(25.0).let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        val displayed60 = receiver(25.0).copy(
            frames = 60,
            presentationIntervalMs = 1000,
            presentedFrames = 59,
            maxRenderGapMs = 22
        )
        repeat(10) { governor.observe(sending60, displayed60, 60, 1000L + it * 1000) }
        assertEquals(60, governor.cap)
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
    @Test fun olderControllerCannotAuthorizeHighCadenceFromSenderHeadroomAlone() {
        val governor = VideoCadenceGovernor(60)
        governor.observe(outbound(40.0), null, 60, 1000)
        governor.observe(outbound(40.0), null, 60, 2000)
        assertEquals(58, governor.cap)
        repeat(16) { governor.observe(outbound(), null, 58, 3000L + it * 1000) }
        assertEquals(58, governor.cap)
    }
    @Test fun healthyPipelinedHardwareIsNotCappedJustBecauseCodecTimeExceedsFrameInterval() {
        val governor = VideoCadenceGovernor(60)
        val sender = outbound(25.0).let { it.copy(recent = it.recent!!.copy(frames = 60)) }
        repeat(10) { governor.observe(sender, receiver(25.0).copy(frames = 60), 60, 1000L + it * 1000) }
        assertEquals(60, governor.cap)
    }
}
