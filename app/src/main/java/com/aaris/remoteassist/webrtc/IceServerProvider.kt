package com.aaris.remoteassist.webrtc

import android.content.Context
import com.aaris.remoteassist.backend.CloudflareBackend
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.webrtc.PeerConnection

object IceServerProvider {
    data class IceConfig(
        val servers: List<PeerConnection.IceServer>,
        val fromBackend: Boolean
    )

    suspend fun load(
        context: Context,
        sessionId: String
    ): List<PeerConnection.IceServer> =
        loadConfig(context, sessionId).servers

    suspend fun loadConfig(
        context: Context,
        sessionId: String,
        timeoutMs: Long = LOAD_TIMEOUT_MS
    ): IceConfig {
        require(sessionId.isNotBlank())
        require(timeoutMs > 0L)
        val fallback = fallbackServers()

        val relayed = runCatching {
            withTimeout(timeoutMs) {
                withContext(Dispatchers.IO) {
                    CloudflareBackend.sessionRequest(
                        context,
                        sessionId,
                        "POST",
                        "ice",
                        JSONObject()
                    ).let {
                        parseIceServers(it.toString())
                    }
                }
            }
        }.getOrDefault(emptyList())

        if (relayed.none(::isTurnServer)) {
            return IceConfig(fallback, false)
        }
        return IceConfig(
            mergeDistinct(relayed, fallback),
            true
        )
    }

    internal fun parseIceServers(
        raw: String
    ): List<PeerConnection.IceServer> {
        val source = JSONObject(raw)
            .optJSONArray("iceServers")
            ?: return emptyList()
        val result =
            ArrayList<PeerConnection.IceServer>()

        for (index in 0 until source.length()) {
            val item =
                source.optJSONObject(index) ?: continue
            val username = item.optString("username")
            val credential = item.optString("credential")
            val urls = when (val value = item.opt("urls")) {
                is String -> listOf(value)
                else -> {
                    val array =
                        item.optJSONArray("urls") ?: continue
                    buildList {
                        for (i in 0 until array.length()) {
                            val url = array.optString(i)
                            if (url.isNotBlank()) add(url)
                        }
                    }
                }
            }

            urls.asSequence()
                .map(String::trim)
                .filter {
                    isUsableIceUrl(
                        it,
                        username,
                        credential
                    )
                }
                .take(MAX_URLS_PER_RESPONSE)
                .forEach { url ->
                    val builder =
                        PeerConnection.IceServer.builder(url)
                    if (username.isNotBlank()) {
                        builder.setUsername(username)
                    }
                    if (credential.isNotBlank()) {
                        builder.setPassword(credential)
                    }
                    result += builder.createIceServer()
                }
            if (result.size >= MAX_ICE_SERVERS) break
        }
        return result.take(MAX_ICE_SERVERS)
    }

    fun fallbackServers(): List<PeerConnection.IceServer> =
        listOf(
            PeerConnection.IceServer.builder(
                "stun:stun.cloudflare.com:3478"
            ).createIceServer(),
            PeerConnection.IceServer.builder(
                "stun:stun.l.google.com:19302"
            ).createIceServer(),
            PeerConnection.IceServer.builder(
                "stun:stun1.l.google.com:19302"
            ).createIceServer()
        )

    internal fun isAllowedIceUrl(url: String): Boolean {
        if (url.length !in 5..MAX_ICE_URL_LENGTH) {
            return false
        }
        val lower = url.lowercase()
        return lower.startsWith("stun:") ||
            lower.startsWith("turn:") ||
            lower.startsWith("turns:")
    }

    internal fun isTurnUrl(url: String): Boolean {
        val lower = url.lowercase()
        return lower.startsWith("turn:") ||
            lower.startsWith("turns:")
    }

    internal fun isUsableIceUrl(
        url: String,
        username: String,
        credential: String
    ): Boolean {
        if (!isAllowedIceUrl(url)) return false
        return !isTurnUrl(url) ||
            (
                username.isNotBlank() &&
                    credential.isNotBlank()
                )
    }

    private fun isTurnServer(
        server: PeerConnection.IceServer
    ): Boolean = server.urls.any(::isTurnUrl)

    private fun mergeDistinct(
        preferred: List<PeerConnection.IceServer>,
        fallback: List<PeerConnection.IceServer>
    ): List<PeerConnection.IceServer> {
        val seen = HashSet<String>()
        val merged =
            ArrayList<PeerConnection.IceServer>()
        (preferred + fallback).forEach { server ->
            val key =
                server.urls.sorted().joinToString("|") +
                    "|" + server.username
            if (seen.add(key)) merged += server
        }
        return merged
    }

    private const val LOAD_TIMEOUT_MS = 7_000L
    private const val MAX_ICE_SERVERS = 16
    private const val MAX_URLS_PER_RESPONSE = 12
    private const val MAX_ICE_URL_LENGTH = 512
}
