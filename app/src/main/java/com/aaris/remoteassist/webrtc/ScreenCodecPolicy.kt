package com.aaris.remoteassist.webrtc

import org.webrtc.RtpCapabilities

/** Prefer actual hardware support, while keeping a negotiated VP8 safety path. */
internal object ScreenCodecPolicy {
    fun preferred(hardware: Set<String>): String = if (hardware.any { it.equals("H264", true) }) "H264" else "VP8"

    private fun usable(codec: RtpCapabilities.CodecCapability, primary: String): Boolean =
        codec.name.equals(primary, true) && (primary != "H264" ||
            (codec.parameters["packetization-mode"] == "1" &&
                codec.parameters["profile-level-id"]?.startsWith("42", true) == true))

    fun order(codecs: List<RtpCapabilities.CodecCapability>, primary: String, exclusive: Boolean = false): List<RtpCapabilities.CodecCapability> {
        val payloads = codecs.filter { usable(it, primary) }.map { it.preferredPayloadType.toString() }.toSet()
        if (payloads.isEmpty()) return if (exclusive) emptyList() else codecs
        fun rank(codec: RtpCapabilities.CodecCapability): Int = when {
            usable(codec, primary) -> 0
            codec.name.equals("RTX", true) && codec.parameters["apt"] in payloads -> 1
            codec.name.uppercase() in setOf("RED", "ULPFEC", "FLEXFEC-03") -> 2
            codec.name.equals("VP8", true) -> 3
            usable(codec, "H264") -> 4
            else -> 5
        }
        return codecs.withIndex().filter { !exclusive || rank(it.value) <= 2 }
            .sortedWith(compareBy({ rank(it.value) }, { it.index })).map { it.value }
    }

    fun remoteSupports(sdp: String, primary: String): Boolean {
        // Only inspect active video sections. Keep capability parsing independent
        // of transport/IP details, and never rewrite SDP strings.
        var video = false
        val lines = sdp.lineSequence().map(String::trim).toList()
        val videoLines = lines.filter { line ->
            if (line.startsWith("m=")) video = line.startsWith("m=video ") && !line.startsWith("m=video 0 ")
            video
        }
        val payloads = videoLines.mapNotNull { Regex("^a=rtpmap:(\\d+) ${Regex.escape(primary)}/90000(?:\\s.*)?$", RegexOption.IGNORE_CASE).find(it)?.groupValues?.get(1) }
        if (primary != "H264") return payloads.isNotEmpty()
        return payloads.any { pt -> videoLines.any { line ->
            if (!line.startsWith("a=fmtp:$pt ")) false else {
                val params = line.substringAfter(' ').split(';').map(String::trim)
                "packetization-mode=1" in params && params.any { it.startsWith("profile-level-id=42", true) }
            }
        } }
    }
}
