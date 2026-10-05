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

    @Test fun defaultTrackerSurfacesHighCadenceStateWithinOneHundredSixtyMilliseconds() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000))
        var sample: PresentationCadenceWindow? = null
        for (time in listOf(
            1_016L, 1_032L, 1_048L, 1_064L, 1_080L,
            1_096L, 1_112L, 1_128L, 1_144L, 1_160L
        )) {
            sample = tracker.onPresented(time) ?: sample
        }
        val result = checkNotNull(sample)
        assertEquals(160, result.intervalMs)
        assertEquals(10, result.renderedFrames)
        assertEquals(16, result.maxGapMs)
        assertEquals(62.5, result.fps, 0.001)
    }

    @Test fun lowCadenceReceiverStillProducesUsableDefaultWindow() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000))
        var sample: PresentationCadenceWindow? = null
        for (time in listOf(1_067L, 1_134L, 1_201L, 1_268L, 1_335L)) {
            sample = tracker.onPresented(time) ?: sample
        }
        val result = checkNotNull(sample)
        assertEquals(335, result.intervalMs)
        assertEquals(5, result.renderedFrames)
        assertEquals(67, result.maxGapMs)
    }

    @Test fun elapsedTimeAloneDoesNotEmitAnUndersampledWindow() {
        val tracker = PresentationCadenceTracker()
        assertNull(tracker.onPresented(1_000))
        assertNull(tracker.onPresented(1_200))
        assertNull(tracker.onPresented(1_400))
        assertNull(tracker.onPresented(1_600))
        assertNull(tracker.onPresented(1_800))
        val result = checkNotNull(tracker.onPresented(2_000))
        assertEquals(1_000, result.intervalMs)
        assertEquals(5, result.renderedFrames)
        assertEquals(200, result.maxGapMs)
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
        assertNull(feedback.consume(42, 2, 201))
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
}
