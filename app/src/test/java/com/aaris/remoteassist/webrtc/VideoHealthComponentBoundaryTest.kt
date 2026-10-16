package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A stream ID/codec MIME is not a lifetime MediaCodec implementation identity.
 * Incomplete vendor labels must not fabricate a replacement or hide a later one.
 */
class VideoHealthComponentBoundaryTest {
    private fun snapshot(
        timestampMs: Long,
        frames: Long,
        implementation: String?,
        direction: String = "outbound",
        stream: String = "video-ssrc",
        codec: String = "video/H264"
    ) = VideoHealthSnapshot(
        direction = direction,
        codec = codec,
        bytes = frames * 1_000,
        frames = frames,
        framesSecondary = frames,
        packets = frames * 2,
        packetsLost = 0,
        frameWidth = 720,
        frameHeight = 1_600,
        qualityLimitationReason = null,
        roundTripTimeMs = null,
        packetLossRatio = null,
        codecImplementation = implementation,
        streamId = stream,
        timestampUs = timestampMs * 1_000.0,
        processingTotalSeconds = frames * 0.005
    )

    @Test fun senderComponentSwapSeedsNewWindowWithoutMixingOldEncoderCounters() {
        val tracker = VideoHealthWindowTracker()
        assertNull(tracker.sample(snapshot(1_000, 100, "c2.vendor.encoder")).recent)
        assertEquals(30, tracker.sample(snapshot(2_000, 130, "C2.VENDOR.ENCODER")).recent?.frames)

        // Same RTP stats ID and H264 codec, different *actual* encoder.
        // Lifetime averages across this boundary would be misleading.
        assertNull(tracker.sample(snapshot(3_000, 140, "omx.vendor.encoder")).recent)
        val newEncoder = tracker.sample(snapshot(4_000, 165, "omx.vendor.encoder"))
        assertEquals(25, newEncoder.recent?.frames)
        assertEquals(25.0, checkNotNull(newEncoder.recent).fps, 0.001)
    }

    @Test fun decoderReplacementAlsoFencesInboundDecodeServiceTime() {
        val tracker = VideoHealthWindowTracker()
        assertNull(tracker.sample(snapshot(1_000, 50, "c2.hw.decoder", "inbound")).recent)
        assertNull(tracker.sample(snapshot(2_000, 60, "c2.sw.decoder", "inbound")).recent)
        val receiver = tracker.sample(snapshot(3_000, 80, "c2.sw.decoder", "inbound"))
        assertEquals(20, receiver.recent?.frames)
        assertEquals(5.0, checkNotNull(receiver.recent?.processingMs), 0.001)
    }

    @Test fun temporarilyMissingLabelsKeepIntervalsButCannotHideFutureSwap() {
        val tracker = VideoHealthWindowTracker()
        assertNull(tracker.sample(snapshot(1_000, 100, "hardware-A")).recent)
        assertEquals(30, tracker.sample(snapshot(2_000, 130, null)).recent?.frames)
        assertEquals(30, tracker.sample(snapshot(3_000, 160, " HARDWARE-A ")).recent?.frames)

        // A vendor reporting a blank label is equivalent to missing metadata.
        assertEquals(20, tracker.sample(snapshot(4_000, 180, " ")).recent?.frames)
        assertNull(tracker.sample(snapshot(5_000, 190, "hardware-B")).recent)
        assertEquals(30, tracker.sample(snapshot(6_000, 220, null)).recent?.frames)
    }

    @Test fun componentSwapDuringEarlyProbeDoesNotBorrowPreSwapBaseline() {
        val tracker = VideoHealthWindowTracker()
        assertNull(tracker.sample(snapshot(1_000, 100, "encoder-A")).recent)
        assertNull(tracker.sample(snapshot(1_120, 105, "encoder-B")).recent)
        // 400 ms is still an incomplete sample after the new encoder seeded.
        assertNull(tracker.sample(snapshot(1_520, 120, "encoder-B")).recent)
        assertEquals(35, tracker.sample(snapshot(2_120, 140, "encoder-B")).recent?.frames)
    }

    @Test fun newStreamAndDiscontinuousClockCannotInheritOldComponentIdentity() {
        val tracker = VideoHealthWindowTracker()
        tracker.sample(snapshot(1_000, 100, "encoder-A"))
        assertNull(tracker.sample(snapshot(2_000, 110, null, stream = "new-ssrc")).recent)
        // A different encoder on a *new* RTP stream is not another boundary:
        // missing implementation metadata must remain compatible.
        assertNotNull(tracker.sample(snapshot(3_000, 140, "encoder-B", stream = "new-ssrc")).recent)
        assertNull(tracker.sample(snapshot(12_000, 150, "encoder-B", stream = "new-ssrc")).recent)
        assertEquals(25, tracker.sample(snapshot(13_000, 175, null, stream = "new-ssrc")).recent?.frames)
    }
}
