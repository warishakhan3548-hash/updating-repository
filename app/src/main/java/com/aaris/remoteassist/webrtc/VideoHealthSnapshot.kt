package com.aaris.remoteassist.webrtc

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
    val qualityLimitationReason: String?
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
                            ?.toString()
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
                    qualityLimitationReason = null
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
    }
}
