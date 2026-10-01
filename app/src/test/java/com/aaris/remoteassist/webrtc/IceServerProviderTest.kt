package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class IceServerProviderTest {
    @Test
    fun parsesCloudflareTurnIceServers() {
        val raw = """
            {
              "iceServers": [
                {
                  "urls": ["stun:stun.cloudflare.com:3478"]
                },
                {
                  "urls": [
                    "turn:turn.cloudflare.com:3478?transport=udp",
                    "turns:turn.cloudflare.com:443?transport=tcp"
                  ],
                  "username": "user",
                  "credential": "pass"
                }
              ]
            }
        """.trimIndent()

        val servers = IceServerProvider.parseIceServers(raw)

        assertEquals(3, servers.size)
        assertTrue(
            servers.any { server ->
                server.urls.any { it.startsWith("turn:") } &&
                    server.username == "user"
            }
        )
        assertTrue(
            servers.any { server ->
                server.urls.any { it.startsWith("turns:") } &&
                    server.username == "user"
            }
        )
    }

    @Test
    fun ignoresUnsupportedIceSchemes() {
        val raw = """
            {
              "iceServers": [
                {
                  "urls": [
                    "https://example.com/not-ice",
                    "turn:turn.cloudflare.com:443?transport=tcp"
                  ],
                  "username": "u",
                  "credential": "p"
                }
              ]
            }
        """.trimIndent()

        val servers = IceServerProvider.parseIceServers(raw)

        assertEquals(1, servers.size)
        assertTrue(servers.single().urls.single().startsWith("turn:"))
    }
}
