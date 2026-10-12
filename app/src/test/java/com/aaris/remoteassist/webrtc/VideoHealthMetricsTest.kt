package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test
import org.webrtc.RTCStats
import org.webrtc.RTCStatsReport

class VideoHealthMetricsTest {
    private fun stat(id: String, type: String, vararg values: Pair<String, Any>) = RTCStats(0, type, id, mapOf(*values))

    @Test fun receiverReportsMeasuredAveragesAndTheSelectedRouteWithoutAddresses() {
        val items = listOf(
            stat("video", "inbound-rtp", "kind" to "video", "transportId" to "transport", "bytesReceived" to 10L,
                "framesDecoded" to 100L, "totalDecodeTime" to 0.7, "jitterBufferDelay" to 4.0,
                "jitterBufferTargetDelay" to 5.5, "jitterBufferEmittedCount" to 100L,
                "framesDropped" to 3L, "freezeCount" to 2L),
            stat("transport", "transport", "selectedCandidatePairId" to "pair"),
            stat("pair", "candidate-pair", "localCandidateId" to "local", "remoteCandidateId" to "remote", "currentRoundTripTime" to 0.04),
            stat("local", "local-candidate", "candidateType" to "relay", "protocol" to "udp", "address" to "private-address"),
            stat("remote", "remote-candidate", "candidateType" to "srflx")
        )
        val snapshot = checkNotNull(VideoHealthSnapshot.from(RTCStatsReport(0, items.associateBy { it.id }), PeerRole.CONTROLLER))
        assertEquals(40, snapshot.roundTripTimeMs)
        assertEquals(40.0, checkNotNull(snapshot.jitterBufferAverageMs), 0.001)
        assertEquals(55.0, checkNotNull(snapshot.jitterBufferTargetAverageMs), 0.001)
        assertEquals(7.0, checkNotNull(snapshot.processingAverageMs), 0.001)
        assertEquals("relay/srflx udp", snapshot.candidatePath)
        assertEquals(2L, snapshot.freezeCount)
        assertFalse(snapshot.compact().contains("private-address"))
    }

    @Test fun intervalWindowKeepsMeasuredResidenceAuthoritativeWhenTargetRunsAhead() {
        fun inbound(
            timestampUs: Long,
            framesDecoded: Long,
            decodeSeconds: Double,
            jitterSeconds: Double,
            targetSeconds: Double,
            emitted: Long
        ): VideoHealthSnapshot {
            val item =
                stat(
                    "video",
                    "inbound-rtp",
                    "kind" to "video",
                    "framesDecoded" to framesDecoded,
                    "bytesReceived" to framesDecoded * 1_000,
                    "packetsReceived" to framesDecoded * 2,
                    "totalDecodeTime" to decodeSeconds,
                    "jitterBufferDelay" to jitterSeconds,
                    "jitterBufferTargetDelay" to targetSeconds,
                    "jitterBufferEmittedCount" to emitted
                )
            return checkNotNull(
                VideoHealthSnapshot.from(
                    RTCStatsReport(
                        timestampUs,
                        mapOf("video" to item)
                    ),
                    PeerRole.CONTROLLER
                )
            )
        }

        val tracker = VideoHealthWindowTracker()
        tracker.sample(
            inbound(
                timestampUs = 1_000_000L,
                framesDecoded = 100,
                decodeSeconds = 0.5,
                jitterSeconds = 1.0,
                targetSeconds = 2.0,
                emitted = 100
            )
        )
        val recent =
            checkNotNull(
                tracker.sample(
                    inbound(
                        timestampUs = 2_000_000L,
                        framesDecoded = 130,
                        decodeSeconds = 0.65,
                        jitterSeconds = 1.3,
                        targetSeconds = 3.5,
                        emitted = 130
                    )
                ).recent
            )

        assertEquals(10.0, checkNotNull(recent.jitterMs), 0.001)
        assertEquals(50.0, checkNotNull(recent.jitterTargetMs), 0.001)
        // The target is predictive scheduling intent, not 50 ms of debt that
        // the emitted frames have already accumulated.
        assertEquals(10.0, checkNotNull(recent.playoutDelayMs), 0.001)
    }

    @Test fun targetDelayRemainsFallbackWhenMeasuredResidenceIsUnavailable() {
        val recent =
            VideoHealthWindow(
                intervalMs = 1_000,
                frames = 30,
                processingMs = 4.0,
                jitterMs = null,
                dropped = 0,
                freezes = 0,
                jitterTargetMs = 50.0
            )

        assertEquals(50.0, checkNotNull(recent.playoutDelayMs), 0.001)
    }

    @Test fun missingOrZeroCountersNeverInventZeroLatency() {
        val item = stat("video", "inbound-rtp", "kind" to "video", "jitterBufferDelay" to 0.0, "jitterBufferEmittedCount" to 0L)
        val snapshot = checkNotNull(VideoHealthSnapshot.from(RTCStatsReport(0, mapOf("video" to item)), PeerRole.CONTROLLER))
        assertNull(snapshot.jitterBufferAverageMs)
        assertNull(snapshot.roundTripTimeMs)
        assertNull(snapshot.freezeCount)
    }

    @Test fun activeOutboundTrackOutranksRetiredSsrcWithMoreLifetimeBytes() {
        val stale = stat(
            "retired", "outbound-rtp",
            "kind" to "video", "active" to false,
            "bytesSent" to 9_000_000L, "framesEncoded" to 900L
        )
        val current = stat(
            "live", "outbound-rtp",
            "kind" to "video", "active" to true,
            "bytesSent" to 300L, "framesEncoded" to 5L
        )
        val snapshot = checkNotNull(
            VideoHealthSnapshot.from(
                RTCStatsReport(1_000_000L, listOf(stale, current).associateBy { it.id }),
                PeerRole.HOST
            )
        )
        assertEquals("live", snapshot.streamId)
        assertEquals(5L, snapshot.frames)
        assertEquals(300L, snapshot.bytes)
    }

    @Test fun inactiveOldTrackCannotMaskLiveTrackWithoutActiveMetadata() {
        val retired = stat(
            "old", "inbound-rtp",
            "kind" to "video", "active" to false,
            "bytesReceived" to 4_000_000L, "framesDecoded" to 200L
        )
        val live = stat(
            "new", "inbound-rtp",
            "kind" to "video",
            "bytesReceived" to 100L, "framesDecoded" to 3L
        )
        val snapshot = checkNotNull(
            VideoHealthSnapshot.from(
                RTCStatsReport(1_000_000L, listOf(retired, live).associateBy { it.id }),
                PeerRole.CONTROLLER
            )
        )
        assertEquals("new", snapshot.streamId)
        assertEquals(3L, snapshot.framesSecondary)
    }

    @Test fun missingActivityMetadataKeepsLegacyCumulativeBytesFallback() {
        val smaller = stat("a", "outbound-rtp", "kind" to "video", "bytesSent" to 10L)
        val larger = stat("b", "outbound-rtp", "kind" to "video", "bytesSent" to 30L)
        val snapshot = checkNotNull(
            VideoHealthSnapshot.from(
                RTCStatsReport(1_000_000L, listOf(smaller, larger).associateBy { it.id }),
                PeerRole.HOST
            )
        )
        assertEquals("b", snapshot.streamId)
    }

    @Test fun outboundRecoveryCountersBecomeIntervalRepairEvidence() {
        fun outbound(
            timestampUs: Long,
            packetsSent: Long,
            retransmittedPacketsSent: Long,
            hugeFramesSent: Long,
            nackCount: Long,
            pliCount: Long,
            firCount: Long,
            keyFramesEncoded: Long,
            framesEncoded: Long
        ): VideoHealthSnapshot {
            val item =
                stat(
                    "video",
                    "outbound-rtp",
                    "kind" to "video",
                    "bytesSent" to packetsSent * 1_000,
                    "packetsSent" to packetsSent,
                    "framesEncoded" to framesEncoded,
                    "framesSent" to framesEncoded,
                    "totalEncodeTime" to framesEncoded * 0.005,
                    "totalPacketSendDelay" to packetsSent * 0.002,
                    "retransmittedPacketsSent" to retransmittedPacketsSent,
                    "hugeFramesSent" to hugeFramesSent,
                    "nackCount" to nackCount,
                    "pliCount" to pliCount,
                    "firCount" to firCount,
                    "keyFramesEncoded" to keyFramesEncoded
                )
            return checkNotNull(
                VideoHealthSnapshot.from(
                    RTCStatsReport(
                        timestampUs,
                        mapOf("video" to item)
                    ),
                    PeerRole.HOST
                )
            )
        }

        val tracker = VideoHealthWindowTracker()
        val first =
            outbound(
                timestampUs = 1_000_000L,
                packetsSent = 100,
                retransmittedPacketsSent = 5,
                hugeFramesSent = 0,
                nackCount = 1,
                pliCount = 0,
                firCount = 0,
                keyFramesEncoded = 1,
                framesEncoded = 20
            )
        assertEquals(5L, first.retransmittedPackets)
        assertEquals(0L, first.hugeFramesSent)
        assertEquals(1L, first.nackCount)
        assertEquals(0L, first.pliCount)
        assertEquals(0L, first.firCount)
        assertEquals(1L, first.keyFrameCount)
        tracker.sample(first)

        val recent =
            checkNotNull(
                tracker.sample(
                    outbound(
                        timestampUs = 2_000_000L,
                        packetsSent = 200,
                        retransmittedPacketsSent = 15,
                        hugeFramesSent = 1,
                        nackCount = 4,
                        pliCount = 1,
                        firCount = 1,
                        keyFramesEncoded = 2,
                        framesEncoded = 50
                    )
                ).recent
            )

        // packetsSent includes retransmissions, so 10 recovered packets out of
        // 100 sent packets is a 10% repair share for this stats window.
        assertEquals(0.10, checkNotNull(recent.retransmitRatio), 0.0001)
        assertEquals(1, recent.hugeFrames)
        assertEquals(3, recent.nacks)
        assertEquals(1, recent.plis)
        assertEquals(1, recent.firs)
        assertEquals(1, recent.keyFrames)
    }
}
