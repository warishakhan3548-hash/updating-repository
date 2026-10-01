package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
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
    fun identifiesRelaySchemes() {
        assertTrue(
            IceServerProvider.isTurnUrl(
                "turn:turn.cloudflare.com:3478?transport=udp"
            )
        )
        assertTrue(
            IceServerProvider.isTurnUrl(
                "turns:turn.cloudflare.com:443?transport=tcp"
            )
        )
        assertFalse(
            IceServerProvider.isTurnUrl(
                "stun:stun.cloudflare.com:3478"
            )
        )
    }

    @Test
    fun ignoresTurnEntriesWithoutCredentials() {
        val parsed = IceServerProvider.parseIceServers(
            """
            {
              "iceServers": [
                {
                  "urls": [
                    "turn:turn.cloudflare.com:3478?transport=udp"
                  ]
                }
              ]
            }
            """.trimIndent()
        )

        assertEquals(0, parsed.size)
    }

    @Test
    fun rejectsUnsupportedAndOversizedUrls() {
        assertFalse(IceServerProvider.isAllowedIceUrl("https://example.org/not-ice"))
        assertFalse(IceServerProvider.isAllowedIceUrl("turn:" + "x".repeat(600)))
    }
}
