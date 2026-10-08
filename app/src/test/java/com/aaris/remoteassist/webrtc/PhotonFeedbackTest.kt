package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import org.junit.Assert.*
import org.junit.Test

class PhotonFeedbackTest {
    private fun packet(sequence: Long = 1L) =
        ControlPacket.PhotonFeedback(
            leaseSecret = 42L,
            generation = 3,
            sequence = sequence,
            inputToGlassUpperBoundMs = 140,
            commandAckMs = 90,
            postAckPresentMs = 50
        )

    @Test
    fun photonPacketRoundTripsAndRejectsInvalidPayloads() {
        val p = packet()
        val bytes = ControlProtocol.encode(p)
        assertEquals(34, bytes.size)
        assertEquals(p, ControlProtocol.decode(bytes))
        assertNull(ControlProtocol.decode(bytes.copyOf(bytes.size - 1)))
        assertNull(ControlProtocol.decode(bytes + byteArrayOf(0)))

        assertThrows(IllegalArgumentException::class.java) {
            ControlProtocol.encode(
                p.copy(
                    inputToGlassUpperBoundMs = 20,
                    commandAckMs = 30
                )
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            ControlProtocol.encode(
                p.copy(postAckPresentMs = 5_001)
            )
        }
        assertNull(
            ControlProtocol.toRemoteCommand(
                sessionId = "s",
                packet = p,
                widthPx = 1080,
                heightPx = 2400
            )
        )
    }

    @Test
    fun photonFeedbackIsLeaseBoundReplaySafeAndRetainedBriefly() {
        val feedback = ReceiverVideoFeedback()
        val p = packet()

        assertFalse(feedback.accept(p, 99, 3, 1_000))
        assertFalse(feedback.accept(p, 42, 4, 1_000))
        assertTrue(feedback.accept(p, 42, 3, 1_000))
        assertFalse(feedback.accept(p, 42, 3, 1_001))

        val first = checkNotNull(feedback.consume(42, 3, 1_050))
        assertEquals(140, first.inputToGlassUpperBoundMs)
        assertEquals(90, first.commandAckMs)
        assertEquals(50, first.postAckPresentMs)
        assertEquals(1L, first.photonSampleSequence)
        assertEquals(50, first.photonSampleAgeMs)
        assertTrue(first.photonSampleFresh)

        val held = checkNotNull(feedback.consume(42, 3, 2_000))
        assertEquals(140, held.inputToGlassUpperBoundMs)
        assertEquals(1L, held.photonSampleSequence)
        assertFalse(held.photonSampleFresh)

        assertNull(
            feedback.consume(42, 3, 4_001)
                ?.inputToGlassUpperBoundMs
        )

        assertTrue(feedback.accept(packet(sequence = 2), 42, 3, 4_100))
        val next = checkNotNull(feedback.consume(42, 3, 4_150))
        assertEquals(2L, next.photonSampleSequence)
        assertTrue(next.photonSampleFresh)
    }

    private fun testedSender(loss: Double?, rtt: Int? = 40): VideoHealthSnapshot =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 1_000,
            frames = 30,
            framesSecondary = 30,
            packets = 90,
            packetsLost = 0,
            frameWidth = 360,
            frameHeight = 800,
            qualityLimitationReason = "none",
            roundTripTimeMs = rtt,
            packetLossRatio = loss,
            recent = VideoHealthWindow(
                intervalMs = 1_000,
                frames = 30,
                processingMs = 5.0,
                jitterMs = null,
                dropped = null,
                freezes = null,
                sendQueueMs = 4.0
            )
        )

    private fun testedGlass(
        dropped: Int? = 0,
        freezes: Int? = 0,
        sampleFresh: Boolean = true
    ): VideoHealthWindow = VideoHealthWindow(
        intervalMs = 1_000,
        frames = 30,
        processingMs = 5.0,
        jitterMs = 8.0,
        dropped = dropped,
        freezes = freezes,
        presentationIntervalMs = 1_000,
        presentedFrames = 30,
        maxRenderGapMs = 34,
        presentationAgeMs = 50,
        presentationSampleAgeMs = 50,
        presentationSampleFresh = sampleFresh
    )

    @Test
    fun missingLossCounterNeedsIndependentCleanGlassAndDecodeProof() {
        val clean = PhotonFreshnessGovernor()
        assertFalse(clean.observe(
            testedSender(null), testedGlass(), 30, true, 1_000L
        ).allowCadencePromotion)
        assertTrue(clean.observe(
            testedSender(null), testedGlass(), 30, true, 2_000L
        ).allowCadencePromotion)

        for ((sender, glass) in listOf(
            testedSender(null) to testedGlass(dropped = 1),
            testedSender(null) to testedGlass(freezes = null),
            testedSender(null) to testedGlass(sampleFresh = false),
            testedSender(null, rtt = null) to testedGlass(),
            testedSender(0.15) to testedGlass(),
            testedSender(Double.NaN) to testedGlass()
        )) {
            val governor = PhotonFreshnessGovernor()
            repeat(4) { sample ->
                assertFalse(governor.observe(
                    sender, glass, 30, true, (sample + 1) * 1_000L
                ).allowCadencePromotion)
            }
        }
    }

}
