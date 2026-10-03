package com.aaris.remoteassist.control

import org.junit.Assert.assertEquals
import org.junit.Test

class FallbackDeltaCapabilityTest {
    @Test
    fun deltaCapabilityRoundTripsWithoutProtocolVersionChange() {
        val packet = ControlPacket.FallbackDeltaReady(998877L)
        assertEquals(
            packet,
            ControlProtocol.decode(ControlProtocol.encode(packet))
        )
    }
}
