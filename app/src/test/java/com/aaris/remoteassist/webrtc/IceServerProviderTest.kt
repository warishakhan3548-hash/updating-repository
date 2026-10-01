package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IceServerProviderTest {
    @Test
    fun acceptsSupportedIceSchemes() {
        assertTrue(IceServerProvider.isAllowedIceUrl("stun:example.org:3478"))
        assertTrue(IceServerProvider.isAllowedIceUrl("turn:example.org:3478?transport=udp"))
        assertTrue(IceServerProvider.isAllowedIceUrl("turns:example.org:443?transport=tcp"))
    }

    @Test
    fun rejectsUnsupportedAndOversizedUrls() {
        assertFalse(IceServerProvider.isAllowedIceUrl("https://example.org/not-ice"))
        assertFalse(IceServerProvider.isAllowedIceUrl("turn:" + "x".repeat(600)))
    }
}
