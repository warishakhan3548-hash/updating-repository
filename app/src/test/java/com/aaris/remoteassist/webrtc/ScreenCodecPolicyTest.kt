package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test
import org.webrtc.RtpCapabilities

class ScreenCodecPolicyTest {
    private fun codec(name: String, pt: Int, vararg params: Pair<String, String>) = RtpCapabilities.CodecCapability().apply {
        this.name = name; preferredPayloadType = pt; parameters = params.toMap()
    }
    private val vp8 = codec("VP8", 96)
    private val vp8Rtx = codec("rtx", 97, "apt" to "96")
    private val baseline = codec("H264", 100, "packetization-mode" to "1", "profile-level-id" to "42e01f")
    private val baselineRtx = codec("rtx", 101, "apt" to "100")
    private val high = codec("H264", 102, "packetization-mode" to "1", "profile-level-id" to "640c1f")
    private val fec = codec("ulpfec", 116)
    private val all = listOf(vp8, vp8Rtx, high, baseline, baselineRtx, fec)

    @Test fun knownHardwareH264ComesFirstWithoutRemovingTheFallback() {
        assertEquals("H264", ScreenCodecPolicy.preferred(setOf("H264")))
        assertEquals("VP8", ScreenCodecPolicy.preferred(emptySet()))
        val order = ScreenCodecPolicy.order(all, "H264")
        assertSame(baseline, order[0]); assertSame(baselineRtx, order[1])
        assertEquals(all.toSet(), order.toSet())
    }
    @Test fun repairUsesOnlySelectedCodecAndItsRetransmissionPayload() {
        val selected = ScreenCodecPolicy.order(all, "VP8", exclusive = true)
        assertEquals(listOf(vp8, vp8Rtx, fec), selected)
        assertEquals(listOf(baseline, baselineRtx, fec), ScreenCodecPolicy.order(all, "H264", exclusive = true))
        assertTrue(ScreenCodecPolicy.order(listOf(high), "H264", exclusive = true).isEmpty())
    }
    @Test fun repairRequiresExplicitRemoteVideoSupportForTheSameH264Profile() {
        val sdp = "m=video 9 UDP/TLS/RTP/SAVPF 96 100\r\na=rtpmap:96 VP8/90000\r\na=rtpmap:100 H264/90000\r\na=fmtp:100 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f\r\n"
        assertTrue(ScreenCodecPolicy.remoteSupports(sdp, "H264"))
        assertTrue(ScreenCodecPolicy.remoteSupports(sdp, "VP8"))
        assertFalse(ScreenCodecPolicy.remoteSupports(sdp.replace("42e01f", "640c1f"), "H264"))
        assertFalse(ScreenCodecPolicy.remoteSupports(sdp.replace("m=video 9", "m=video 0"), "H264"))
        assertFalse(ScreenCodecPolicy.remoteSupports(sdp.replace("m=video", "m=audio"), "H264"))
    }
}
