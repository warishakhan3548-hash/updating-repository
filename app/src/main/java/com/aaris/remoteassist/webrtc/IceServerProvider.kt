package com.aaris.remoteassist.webrtc

import com.google.firebase.auth.FirebaseAuth
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
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
        sessionId: String
    ): List<PeerConnection.IceServer> =
        loadConfig(sessionId).servers

    suspend fun loadConfig(
        sessionId: String,
        timeoutMs: Long = LOAD_TIMEOUT_MS
    ): IceConfig {
        require(sessionId.isNotBlank())
        require(timeoutMs > 0L)

        val fallback = fallbackServers()

        val relayed = runCatching {
            withTimeout(timeoutMs) {
                val user = FirebaseAuth.getInstance().currentUser
                    ?: return@withTimeout emptyList()

                val token = user.getIdToken(false).await().token
                    ?.takeIf(String::isNotBlank)
                    ?: return@withTimeout emptyList()

                fetchTurnServers(
                    idToken = token,
                    connectTimeoutMs = timeoutMs.coerceAtMost(
                        MAX_HTTP_TIMEOUT_MS
                    ).toInt()
                )
            }
        }.getOrDefault(emptyList())

        if (relayed.none(::isTurnServer)) {
            return IceConfig(
                servers = fallback,
                fromBackend = false
            )
        }

        return IceConfig(
            servers = mergeDistinct(
                preferred = relayed,
                fallback = fallback
            ),
            fromBackend = true
        )
    }

    internal fun parseIceServers(raw: String): List<PeerConnection.IceServer> {
        val root = JSONObject(raw)
        val source = root.optJSONArray("iceServers")
            ?: return emptyList()
        val result = ArrayList<PeerConnection.IceServer>()

        for (index in 0 until source.length()) {
            val item = source.optJSONObject(index) ?: continue
            val username = item.optString("username")
            val credential = item.optString("credential")

            val urls = when (val value = item.opt("urls")) {
                is String -> listOf(value)
                else -> {
                    val array = item.optJSONArray("urls")
                        ?: continue
                    buildList {
                        for (urlIndex in 0 until array.length()) {
                            val candidate = array.optString(urlIndex)
                            if (candidate.isNotBlank()) add(candidate)
                        }
                    }
                }
            }

            urls.asSequence()
                .map(String::trim)
                .filter(::isAllowedIceUrl)
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

    fun fallbackServers(): List<PeerConnection.IceServer> = listOf(
        PeerConnection.IceServer.builder(
            "stun:stun.l.google.com:19302"
        ).createIceServer(),
        PeerConnection.IceServer.builder(
            "stun:stun1.l.google.com:19302"
        ).createIceServer(),
        PeerConnection.IceServer.builder(
            "stun:stun.cloudflare.com:3478"
        ).createIceServer()
    )

    private suspend fun fetchTurnServers(
        idToken: String,
        connectTimeoutMs: Int
    ): List<PeerConnection.IceServer> = withContext(Dispatchers.IO) {
        val connection =
            URL(ICE_CONFIG_ENDPOINT).openConnection() as HttpURLConnection

        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = connectTimeoutMs
            connection.instanceFollowRedirects = false
            connection.doOutput = false
            connection.setRequestProperty(
                "Authorization",
                "Bearer $idToken"
            )
            connection.setRequestProperty(
                "Accept",
                "application/json"
            )

            if (connection.responseCode !in 200..299) {
                return@withContext emptyList()
            }

            val body = connection.inputStream
                .bufferedReader()
                .use { it.readText() }

            parseIceServers(body)
        } finally {
            connection.disconnect()
        }
    }

    private fun isAllowedIceUrl(url: String): Boolean {
        if (url.length !in 5..MAX_ICE_URL_LENGTH) return false
        val lower = url.lowercase()
        return lower.startsWith("stun:") ||
            lower.startsWith("turn:") ||
            lower.startsWith("turns:")
    }

    private fun isTurnServer(
        server: PeerConnection.IceServer
    ): Boolean = server.urls.any { url ->
        val lower = url.lowercase()
        lower.startsWith("turn:") ||
            lower.startsWith("turns:")
    }

    private fun mergeDistinct(
        preferred: List<PeerConnection.IceServer>,
        fallback: List<PeerConnection.IceServer>
    ): List<PeerConnection.IceServer> {
        val seen = HashSet<String>()
        val merged = ArrayList<PeerConnection.IceServer>()

        (preferred + fallback).forEach { server ->
            val key = server.urls
                .sorted()
                .joinToString("|") +
                "|" + server.username

            if (seen.add(key)) {
                merged += server
            }
        }

        return merged
    }

    private const val ICE_CONFIG_ENDPOINT =
        "https://aaris-remote-ice.aaris-remote-wk3548.workers.dev/v1/ice"
    private const val LOAD_TIMEOUT_MS = 4_000L
    private const val MAX_HTTP_TIMEOUT_MS = 3_500L
    private const val MAX_ICE_SERVERS = 16
    private const val MAX_URLS_PER_RESPONSE = 12
    private const val MAX_ICE_URL_LENGTH = 512
}
