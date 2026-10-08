package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import org.junit.Assert.*
import org.junit.Test

class PresentationFeedbackTest {
    @Test fun trackerMeasuresActualSwapCadenceAndLargestGap() {
        val tracker = PresentationCadenceTracker(minWindowMs = 500)
        assertNull(tracker.onPresented(1_000))
        var sample: PresentationCadenceWindow? = null
        for (time in listOf(1_016L, 1_032L, 1_048L, 1_080L, 1_096L, 1_200L, 1_300L, 1_400L, 1_500L)) {
            sample = tracker.onPresented(time) ?: sample
        }
        val result = checkNotNull(sample)
        assertEquals(500, result.intervalMs)
        assertEquals(9, result.renderedFrames)
        assertEquals(104, result.maxGapMs)
    }

    @Test fun defaultTrackerSurfacesPresentationStateWithinHalfSecond() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000))
        assertNull(tracker.onPresented(1_250))
        val result = checkNotNull(tracker.onPresented(1_500))
        assertEquals(500, result.intervalMs)
        assertEquals(2, result.renderedFrames)
        assertEquals(250, result.maxGapMs)
    }

    @Test fun backwardsOrVeryStaleClockResetsInsteadOfInventingJank() {
        val tracker = PresentationCadenceTracker(minWindowMs = 500)
        tracker.onPresented(1_000)
        tracker.onPresented(1_100)
        assertNull(tracker.onPresented(900))
        assertNull(tracker.onPresented(8_000))
    }

    @Test fun presentationPacketRoundTripsAndRejectsMalformedWindows() {
        val packet = ControlPacket.PresentationFeedback(42, 3, 7, 1000, 55, 41)
        val bytes = ControlProtocol.encode(packet)
        assertEquals(34, bytes.size)
        assertEquals(packet, ControlProtocol.decode(bytes))
        assertNull(ControlProtocol.toRemoteCommand("session", packet, 1080, 2400))
        assertNull(ControlProtocol.decode(bytes.copyOf(bytes.size - 1)))
        assertThrows(IllegalArgumentException::class.java) {
            ControlProtocol.encode(packet.copy(renderedFrames = 0))
        }
    }

    @Test fun presentationHeartbeatRoundTripsAndProvesGlassWithoutInventingFps() {
        val packet = ControlPacket.PresentationHeartbeat(42, 3, 9)
        val bytes = ControlProtocol.encode(packet)
        assertEquals(22, bytes.size)
        assertEquals(packet, ControlProtocol.decode(bytes))
        assertNull(ControlProtocol.toRemoteCommand("session", packet, 1080, 2400))
        assertNull(ControlProtocol.decode(bytes.copyOf(bytes.size - 1)))

        val feedback = ReceiverVideoFeedback()
        assertTrue(feedback.accept(packet, 42, 3, 1_000))
        val liveness = checkNotNull(feedback.consume(42, 3, 1_240))
        assertEquals(240, liveness.presentationAgeMs)
        assertNull(liveness.presentedFps)
        assertFalse(feedback.accept(packet, 42, 3, 1_300))
        assertFalse(feedback.accept(packet.copy(sequence = 10), 42, 4, 1_300))
    }

    @Test fun displayCapabilitySurvivesMissingPresentationWindows() {
        val feedback = ReceiverVideoFeedback()
        val capability = ControlPacket.DisplayCapabilities(42, 2, 1, 120f)
        assertTrue(feedback.accept(capability, 42, 2, 1_000))

        // No EGL presentation or decoder window arrives for several seconds.
        // The display ceiling is control-plane capability and must remain known.
        val heartbeat = ControlPacket.PresentationHeartbeat(42, 2, 2)
        assertTrue(feedback.accept(heartbeat, 42, 2, 6_000))
        val window = checkNotNull(feedback.consume(42, 2, 6_100))
        assertEquals(120.0, window.displayRefreshRateHz!!, 0.001)

        // Capability eventually expires if the controller really disappears.
        val lateHeartbeat = ControlPacket.PresentationHeartbeat(42, 2, 3)
        assertTrue(feedback.accept(lateHeartbeat, 42, 2, 17_000))
        val stale = checkNotNull(feedback.consume(42, 2, 17_100))
        assertNull(stale.displayRefreshRateHz)
    }

    @Test fun leaseBoundAggregatorMergesDecoderAndActualPresentationWindows() {
        val feedback = ReceiverVideoFeedback()
        val video = ControlPacket.VideoFeedback(42, 2, 1, 1000, 60, 5f, 12f, 0, 0)
        val display = ControlPacket.PresentationFeedback(42, 2, 1, 1000, 38, 72)
        assertTrue(feedback.accept(video, 42, 2, 100))
        assertTrue(feedback.accept(display, 42, 2, 120))
        val merged = checkNotNull(feedback.consume(42, 2, 200))
        assertEquals(60, merged.frames)
        assertEquals(38, merged.presentedFrames)
        assertEquals(38.0, merged.presentedFps!!, 0.001)
        assertEquals(72, merged.maxRenderGapMs)
        val held = checkNotNull(feedback.consume(42, 2, 201))
        assertEquals(81, held.presentationAgeMs)
        // The same measured EGL window is retained briefly to bridge the
        // independent render/stats clocks, but is explicitly marked held so
        // adaptation cannot count it as a second proof or pressure event.
        assertEquals(38.0, held.presentedFps!!, 0.001)
        assertEquals(1L, held.presentationSampleSequence)
        assertEquals(81, held.presentationSampleAgeMs)
        assertFalse(held.presentationSampleFresh)
        assertFalse(feedback.accept(display, 42, 3, 300))
    }

    @Test fun consecutivePresentationWindowsAggregateAndKeepWorstRenderGap() {
        val feedback = ReceiverVideoFeedback()
        val first = ControlPacket.PresentationFeedback(42, 2, 1, 500, 30, 24)
        val second = ControlPacket.PresentationFeedback(42, 2, 2, 500, 20, 140)

        assertTrue(feedback.accept(first, 42, 2, 100))
        assertTrue(feedback.accept(second, 42, 2, 620))

        val merged = checkNotNull(feedback.consume(42, 2, 900))
        assertEquals(1_000, merged.presentationIntervalMs)
        assertEquals(50, merged.presentedFrames)
        assertEquals(50.0, merged.presentedFps!!, 0.001)
        assertEquals(140, merged.maxRenderGapMs)
    }

    @Test fun missingCompositorReportsCannotBeFabricatedIntoContinuousFps() {
        val feedback = ReceiverVideoFeedback()
        val beforeDrop = ControlPacket.PresentationFeedback(42, 2, 1, 500, 30, 30)
        val afterDrop = ControlPacket.PresentationFeedback(42, 2, 2, 500, 8, 210)

        assertTrue(feedback.accept(beforeDrop, 42, 2, 100))
        // A lost telemetry packet or hidden/stalled viewer leaves a 1.3 s
        // arrival hole. These two measured 500 ms windows are not contiguous.
        assertTrue(feedback.accept(afterDrop, 42, 2, 1_400))

        val sample = checkNotNull(feedback.consume(42, 2, 1_420))
        assertEquals(500, sample.presentationIntervalMs)
        assertEquals(8, sample.presentedFrames)
        assertEquals(16.0, sample.presentedFps!!, 0.001)
        assertEquals(210, sample.maxRenderGapMs)
        assertTrue(sample.presentationSampleFresh)
        assertEquals(2L, sample.presentationSampleSequence)
    }

    @Test fun veryOldJankCannotPolluteNewHealthyPresentationEvidence() {
        val feedback = ReceiverVideoFeedback()
        val oldJank = ControlPacket.PresentationFeedback(42, 2, 1, 500, 1, 490)
        val newHealthy = ControlPacket.PresentationFeedback(42, 2, 2, 500, 30, 20)

        assertTrue(feedback.accept(oldJank, 42, 2, 100))
        assertTrue(feedback.accept(newHealthy, 42, 2, 4_200))

        val sample = checkNotNull(feedback.consume(42, 2, 4_250))
        assertEquals(500, sample.presentationIntervalMs)
        assertEquals(30, sample.presentedFrames)
        assertEquals(60.0, sample.presentedFps!!, 0.001)
        assertEquals(20, sample.maxRenderGapMs)
    }

    @Test fun normalArrivalJitterStillAllowsConsecutiveWindowsToAggregate() {
        val feedback = ReceiverVideoFeedback()
        val first = ControlPacket.PresentationFeedback(42, 2, 1, 500, 30, 20)
        val second = ControlPacket.PresentationFeedback(42, 2, 2, 500, 29, 35)

        assertTrue(feedback.accept(first, 42, 2, 100))
        // 900 ms between receive callbacks is allowed for a 500 ms sample
        // plus network/scheduler jitter; do not fragment all healthy traffic.
        assertTrue(feedback.accept(second, 42, 2, 1_000))

        val sample = checkNotNull(feedback.consume(42, 2, 1_050))
        assertEquals(1_000, sample.presentationIntervalMs)
        assertEquals(59, sample.presentedFrames)
        assertEquals(59.0, sample.presentedFps!!, 0.001)
        assertEquals(35, sample.maxRenderGapMs)
    }
}
