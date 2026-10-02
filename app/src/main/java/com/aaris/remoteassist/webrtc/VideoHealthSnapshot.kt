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
    val packetLossRatio: Double?
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

            val selected = candidates.maxByOrNull { stat ->
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

            val roundTripTimeMs =
                decimal(
                    remoteInbound
                        ?.members
                        ?.get("roundTripTime")
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
                    packetLossRatio = packetLossRatio
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
                    roundTripTimeMs = null,
                    packetLossRatio = null
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
