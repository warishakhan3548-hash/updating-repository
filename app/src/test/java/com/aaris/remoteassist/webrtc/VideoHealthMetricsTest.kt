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

    @Test fun intervalWindowKeepsTargetPlayoutAsAnEarlyFreshnessSignal() {
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
        assertEquals(50.0, checkNotNull(recent.playoutDelayMs), 0.001)
    }

    @Test fun missingOrZeroCountersNeverInventZeroLatency() {
        val item = stat("video", "inbound-rtp", "kind" to "video", "jitterBufferDelay" to 0.0, "jitterBufferEmittedCount" to 0L)
        val snapshot = checkNotNull(VideoHealthSnapshot.from(RTCStatsReport(0, mapOf("video" to item)), PeerRole.CONTROLLER))
        assertNull(snapshot.jitterBufferAverageMs)
        assertNull(snapshot.roundTripTimeMs)
        assertNull(snapshot.freezeCount)
    }
}
