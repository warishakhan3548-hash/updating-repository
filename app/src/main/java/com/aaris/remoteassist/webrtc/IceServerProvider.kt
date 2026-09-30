package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.backend.BackendConfig
import com.google.firebase.functions.FirebaseFunctions
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeout
import org.webrtc.PeerConnection

object IceServerProvider {
    suspend fun load(): List<PeerConnection.IceServer> {
        val fallback = fallbackServers()

        val result = runCatching {
            withTimeout(LOAD_TIMEOUT_MS) {
                FirebaseFunctions
                    .getInstance(BackendConfig.FUNCTIONS_REGION)
                    .getHttpsCallable("getIceConfig")
                    .call()
                    .await()
            }
        }.getOrNull() ?: return fallback

        val root = result.data as? Map<*, *> ?: return fallback
        val parsed = parseServers(root["iceServers"])
        return parsed.ifEmpty { fallback }
    }

    fun fallbackServers(): List<PeerConnection.IceServer> = listOf(
        PeerConnection.IceServer.builder(
            "stun:stun.l.google.com:19302"
        ).createIceServer(),
        PeerConnection.IceServer.builder(
            "stun:stun1.l.google.com:19302"
        ).createIceServer()
    )

    private fun parseServers(raw: Any?): List<PeerConnection.IceServer> {
        val rows = raw as? List<*> ?: return emptyList()
        val output = ArrayList<PeerConnection.IceServer>()

        for (row in rows) {
            val map = row as? Map<*, *> ?: continue
            val urls = when (val value = map["urls"]) {
                is String -> listOf(value)
                is List<*> -> value.mapNotNull { it as? String }
                else -> emptyList()
            }
            val username = (map["username"] as? String)
                ?.take(MAX_CREDENTIAL_CHARS)
            val credential = (map["credential"] as? String)
                ?.take(MAX_CREDENTIAL_CHARS)

            for (rawUrl in urls) {
                if (output.size >= MAX_ICE_SERVERS) break

                val url = rawUrl.trim()
                if (!isAllowedIceUrl(url)) continue

                val builder = PeerConnection.IceServer.builder(url)
                if (!username.isNullOrBlank()) {
                    builder.setUsername(username)
                }
                if (!credential.isNullOrBlank()) {
                    builder.setPassword(credential)
                }
                output += builder.createIceServer()
            }

            if (output.size >= MAX_ICE_SERVERS) break
        }

        return output
    }

    private fun isAllowedIceUrl(url: String): Boolean {
        if (url.length !in 6..MAX_URL_CHARS) return false
        return url.startsWith("stun:", ignoreCase = true) ||
            url.startsWith("stuns:", ignoreCase = true) ||
            url.startsWith("turn:", ignoreCase = true) ||
            url.startsWith("turns:", ignoreCase = true)
    }

    private const val LOAD_TIMEOUT_MS = 4_000L
    private const val MAX_ICE_SERVERS = 12
    private const val MAX_URL_CHARS = 512
    private const val MAX_CREDENTIAL_CHARS = 512
}
