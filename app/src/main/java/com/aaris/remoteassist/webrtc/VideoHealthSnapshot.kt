package com.aaris.remoteassist.webrtc

import kotlin.math.roundToInt
import org.webrtc.RTCStatsReport

data class VideoHealthSnapshot(
    val direction: String,
    val codec: String?,
    val bytes: Long,
    val frames: Long,
    val framesSecondary: Long,
    val packets: Long,
    val packetsLost: Long,
    val frameWidth: Int,
    val frameHeight: Int,
    val qualityLimitationReason: String?,
    val roundTripTimeMs: Int?,
    val packetLossRatio: Double?,
    val jitterBufferAverageMs: Double? = null,
    val jitterBufferTargetAverageMs: Double? = null,
    val processingAverageMs: Double? = null,
    val framesDropped: Long? = null,
    val freezeCount: Long? = null,
    val candidatePath: String? = null,
    val codecImplementation: String? = null,
    val streamId: String = "",
    val timestampUs: Double = 0.0,
    val processingTotalSeconds: Double? = null,
    val jitterTotalSeconds: Double? = null,
    val jitterTargetTotalSeconds: Double? = null,
    val jitterEmittedCount: Long? = null,
    val sendDelayTotalSeconds: Double? = null,
    val retransmittedPackets: Long? = null,
    val nackCount: Long? = null,
    val pliCount: Long? = null,
    val keyFrameCount: Long? = null,
    val recent: VideoHealthWindow? = null,
    val availableOutgoingBitrateBps: Double? = null
) {
    fun compact(): String {
        val primary =
            if (direction == "outbound") {
                "encoded=$frames sent=$framesSecondary bytes=$bytes"
            } else {
                "received=$frames decoded=$framesSecondary bytes=$bytes"
            }

        return buildString {
            append("video ")
            append(direction)
            append(" • ")
            append(primary)
            append(" packets=")
            append(packets)
            if (packetsLost > 0) {
                append(" lost=")
                append(packetsLost)
            }
            if (frameWidth > 0 && frameHeight > 0) {
                append(" ")
                append(frameWidth)
                append("x")
                append(frameHeight)
            }
            codec?.takeIf(String::isNotBlank)?.let {
                append(" codec=")
                append(it)
            }
            qualityLimitationReason
                ?.takeIf {
                    it.isNotBlank() &&
                        !it.equals("none", ignoreCase = true)
                }
                ?.let {
                    append(" limited=")
                    append(it)
                }
            roundTripTimeMs?.let {
                append(" rtt=")
                append(it)
                append("ms")
            }
            availableOutgoingBitrateBps?.let {
                append(" bwe=")
                append((it / 1_000.0).roundToInt())
                append("kbps")
            }
            jitterBufferAverageMs?.let { append(" jitterAvg=${it.roundToInt()}ms") }
            jitterBufferTargetAverageMs?.let {
                append(" jitterTarget=${it.roundToInt()}ms")
            }
            processingAverageMs?.let { append(" codecAvg=${it.roundToInt()}ms") }
            framesDropped?.let { append(" dropped=$it") }
            freezeCount?.let { append(" freezes=$it") }
            candidatePath?.let { append(" path=$it") }
            codecImplementation?.let { append(" implementation=$it") }
            recent?.let { append(" recent={${it.compact()}}") }
            packetLossRatio?.let {
                append(" loss=")
                append(
                    ((it * 1000.0).roundToInt() / 10.0)
                )
                append("%")
            }
        }
    }

    companion object {
        fun from(
            report: RTCStatsReport,
            role: PeerRole
        ): VideoHealthSnapshot? {
            val type =
                if (role == PeerRole.HOST) {
                    "outbound-rtp"
                } else {
                    "inbound-rtp"
                }

            val stats = report.statsMap
            val candidates =
                stats.values.filter { stat ->
                    if (stat.type != type) return@filter false
                    val kind =
                        stat.members["kind"]?.toString()
                            ?: stat.members["mediaType"]?.toString()
                    kind.equals("video", ignoreCase = true)
                }

            /*
             * An SSRC replaced during ICE/codec recovery may remain in getStats
             * with more lifetime bytes than the new active screen stream.
             * Picking max(bytes) alone silently binds health/adaptation to the
             * retired track. Prefer an explicitly active RTP report, and never
             * prefer an explicitly inactive one over an unmarked live report.
             *
             * Older WebRTC/OEM builds can omit "active": retain the original
             * cumulative-byte fallback when activity information is absent.
             */
            val viable = candidates.filterNot { it.members["active"] == false }
                .ifEmpty { candidates }
            val active = viable.filter { it.members["active"] == true }
            val selected = (active.ifEmpty { viable }).maxByOrNull { stat ->
                number(stat.members["bytesSent"])
                    .coerceAtLeast(
                        number(stat.members["bytesReceived"])
                    )
            } ?: return null

            val members = selected.members
            val codecId = members["codecId"]?.toString()
            val codec =
                codecId
                    ?.let(stats::get)
                    ?.members
                    ?.get("mimeType")
                    ?.toString()

            val remoteInbound =
                if (role == PeerRole.HOST) {
                    /*
                     * remote-inbound-rtp.localId points back to the local
                     * outbound RTP stats object. Correlate that relationship
                     * first so audio/other RTP stats cannot accidentally drive
                     * the screen-quality governor when a platform omits "kind".
                     * Keep the older video-shaped fallback for vendor builds
                     * that do not expose localId.
                     */
                    stats.values.firstOrNull { stat ->
                        stat.type == "remote-inbound-rtp" &&
                            stat.members["localId"]
                                ?.toString() == selected.id
                    } ?: stats.values.firstOrNull { stat ->
                        if (stat.type != "remote-inbound-rtp") {
                            return@firstOrNull false
                        }

                        val kind =
                            stat.members["kind"]?.toString()
                                ?: stat.members["mediaType"]?.toString()

                        kind.equals("video", ignoreCase = true) ||
                            (
                                kind == null &&
                                    (
                                        stat.members.containsKey("roundTripTime") ||
                                            stat.members.containsKey("fractionLost")
                                        )
                                )
                    }
                } else {
                    null
                }

            val transport = members["transportId"]?.toString()?.let(stats::get)
            val pair = transport?.members?.get("selectedCandidatePairId")?.toString()?.let(stats::get)
                ?: stats.values.firstOrNull { it.type == "candidate-pair" &&
                    it.members["state"] == "succeeded" &&
                    (it.members["selected"] == true || it.members["nominated"] == true) }
            val localCandidate = pair?.members?.get("localCandidateId")?.toString()?.let(stats::get)
            val remoteCandidate = pair?.members?.get("remoteCandidateId")?.toString()?.let(stats::get)
            val candidatePath = localCandidate?.let { local ->
                buildString {
                    append(local.members["candidateType"] ?: "?")
                    append("/")
                    append(
                        remoteCandidate
                            ?.members
                            ?.get("candidateType")
                            ?: "?"
                    )
                    append(" ")
                    append(local.members["protocol"] ?: "?")
                    local.members["relayProtocol"]
                        ?.toString()
                        ?.takeIf(String::isNotBlank)
                        ?.let {
                            append(" relay=")
                            append(it)
                        }
                    local.members["networkType"]
                        ?.toString()
                        ?.takeIf(String::isNotBlank)
                        ?.let {
                            append(" net=")
                            append(it)
                        }
                }
            }
            fun meanMs(total: String, count: String): Double? {
                val seconds = decimal(members[total]) ?: return null
                val n = decimal(members[count]) ?: return null
                return if (seconds.isFinite() && seconds >= 0 && n.isFinite() && n > 0) seconds * 1000 / n else null
            }
            val roundTripTimeMs =
                decimal(
                    remoteInbound
                        ?.members
                        ?.get("roundTripTime") ?: pair?.members?.get("currentRoundTripTime")
                )
                    ?.takeIf { it.isFinite() && it >= 0.0 }
                    ?.times(1_000.0)
                    ?.roundToInt()

            val packetLossRatio =
                decimal(
                    remoteInbound
                        ?.members
                        ?.get("fractionLost")
                )
                    ?.takeIf { it.isFinite() && it >= 0.0 }
                    ?.coerceIn(0.0, 1.0)
            val availableOutgoingBitrateBps =
                decimal(
                    pair?.members?.get("availableOutgoingBitrate")
                )?.takeIf { it.isFinite() && it > 0.0 }

            return if (role == PeerRole.HOST) {
                VideoHealthSnapshot(
                    direction = "outbound",
                    codec = codec,
                    bytes = number(members["bytesSent"]),
                    frames = number(members["framesEncoded"]),
                    framesSecondary =
                        number(members["framesSent"]),
                    packets = number(members["packetsSent"]),
                    packetsLost = 0L,
                    frameWidth =
                        number(members["frameWidth"]).toInt(),
                    frameHeight =
                        number(members["frameHeight"]).toInt(),
                    qualityLimitationReason =
                        members["qualityLimitationReason"]
                            ?.toString(),
                    roundTripTimeMs = roundTripTimeMs,
                    packetLossRatio = packetLossRatio,
                    processingAverageMs = meanMs("totalEncodeTime", "framesEncoded"),
                    candidatePath = candidatePath,
                    codecImplementation = members["encoderImplementation"]?.toString(),
                    availableOutgoingBitrateBps = availableOutgoingBitrateBps,
                    streamId = selected.id, timestampUs = report.timestampUs,
                    processingTotalSeconds = decimal(members["totalEncodeTime"]),
                    sendDelayTotalSeconds = decimal(members["totalPacketSendDelay"]),
                    /*
                     * Recovery counters are cumulative RTP stats. Keep them
                     * optional because Android/OEM WebRTC builds do not expose
                     * every counter. VideoHealthWindowTracker converts only
                     * comparable consecutive samples into interval evidence.
                     */
                    retransmittedPackets =
                        members["retransmittedPacketsSent"]?.let(::number),
                    nackCount = members["nackCount"]?.let(::number),
                    pliCount = members["pliCount"]?.let(::number),
                    keyFrameCount =
                        members["keyFramesEncoded"]?.let(::number)
                )
            } else {
                VideoHealthSnapshot(
                    direction = "inbound",
                    codec = codec,
                    bytes = number(members["bytesReceived"]),
                    frames = number(members["framesReceived"]),
                    framesSecondary =
                        number(members["framesDecoded"]),
                    packets = number(members["packetsReceived"]),
                    packetsLost =
                        number(members["packetsLost"]),
                    frameWidth =
                        number(members["frameWidth"]).toInt(),
                    frameHeight =
                        number(members["frameHeight"]).toInt(),
                    qualityLimitationReason = null,
                    roundTripTimeMs = roundTripTimeMs,
                    packetLossRatio = null,
                    jitterBufferAverageMs = meanMs("jitterBufferDelay", "jitterBufferEmittedCount"),
                    jitterBufferTargetAverageMs =
                        meanMs("jitterBufferTargetDelay", "jitterBufferEmittedCount"),
                    processingAverageMs = meanMs("totalDecodeTime", "framesDecoded"),
                    framesDropped = members["framesDropped"]?.let(::number),
                    freezeCount = members["freezeCount"]?.let(::number),
                    candidatePath = candidatePath,
                    codecImplementation = members["decoderImplementation"]?.toString(),
                    streamId = selected.id, timestampUs = report.timestampUs,
                    processingTotalSeconds = decimal(members["totalDecodeTime"]),
                    jitterTotalSeconds = decimal(members["jitterBufferDelay"]),
                    jitterTargetTotalSeconds =
                        decimal(members["jitterBufferTargetDelay"]),
                    jitterEmittedCount = members["jitterBufferEmittedCount"]?.let(::number)
                )
            }
        }

        private fun number(value: Any?): Long =
            when (value) {
                is Byte -> value.toLong()
                is Short -> value.toLong()
                is Int -> value.toLong()
                is Long -> value
                is Float -> value.toLong()
                is Double -> value.toLong()
                is Number -> value.toLong()
                else ->
                    value?.toString()?.toDoubleOrNull()?.toLong()
                        ?: 0L
            }

        private fun decimal(value: Any?): Double? =
            when (value) {
                is Number -> value.toDouble()
                else -> value?.toString()?.toDoubleOrNull()
            }
    }
}
