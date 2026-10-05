package com.aaris.remoteassist.backend

import java.io.IOException
import java.io.InterruptedIOException
import java.net.ProtocolException
import java.net.SocketTimeoutException
import java.util.Locale
import javax.net.ssl.SSLException
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink
import org.json.JSONObject

/** Both fixed origins reach the same Worker and Durable Object namespaces. */
internal class BackendTransport(
    client: OkHttpClient,
    private val origins: List<HttpUrl>
) {
    init {
        require(origins.size == 2 && origins.distinct().size == 2)
        require(origins.all { it.encodedPath == "/" && it.query == null })
    }

    private var preferred = origins.first()

    val httpClient = client.newBuilder()
        // Never redirect a session credential to an unconfigured origin.
        .followRedirects(false)
        .followSslRedirects(false)
        .eventListenerFactory { call ->
            call.request().tag(RequestProgress::class.java) ?: EventListener.NONE
        }
        .build()

    @Synchronized fun currentOrigin(): HttpUrl = preferred

    @Synchronized fun connected(url: HttpUrl) {
        origins.firstOrNull { it.sameOrigin(url) }?.let { preferred = it }
    }

    @Synchronized fun connectionFailed(url: HttpUrl, error: IOException) {
        if (recoverable(error) && preferred.sameOrigin(url)) {
            preferred = origins.first { it != preferred }
        }
    }

    fun execute(method: String, path: String, token: String?, body: JSONObject?): JSONObject {
        require(path.startsWith("/") && !path.startsWith("//"))
        val verb = method.uppercase(Locale.US)
        val replayable = replayable(verb, path, body)
        val first = currentOrigin()
        val attempts = listOf(first, origins.first { it != first })
        var previous: IOException? = null
        for ((index, origin) in attempts.withIndex()) {
            val progress = RequestProgress()
            val request = Request.Builder()
                .url(origin.resolve(path)!!)
                .header("Accept", "application/json")
                .header("Cache-Control", "no-store")
                .tag(RequestProgress::class.java, progress)
                .apply { if (!token.isNullOrBlank()) header("Authorization", "Bearer $token") }
                .method(verb, if (verb == "GET" || verb == "HEAD") null else jsonBody(body, replayable))
                .build()
            try {
                httpClient.newCall(request).execute().use { response ->
                    val result = readResponse(response)
                    connected(origin)
                    return result
                }
            } catch (error: IOException) {
                if (error is CloudflareBackendException || !recoverable(error)) throw error
                connectionFailed(origin, error)
                previous?.let { error.addSuppressed(it) }
                // A lost response cannot justify creating another session or
                // publishing an event twice. Redemption carries one stable
                // controller token, and its server-side retry is idempotent.
                if ((!replayable && progress.headersStarted) || index == attempts.lastIndex) {
                    throw CloudflareBackendException(
                        0, "backend_unreachable",
                        "Could not reach Aaris Remote. Try Wi-Fi or mobile data, then retry."
                    ).apply { initCause(error) }
                }
                previous = error
            }
        }
        error("No backend origins")
    }

    private class RequestProgress : EventListener() {
        @Volatile var headersStarted = false
        override fun requestHeadersStart(call: Call) { headersStarted = true }
    }

    private fun jsonBody(body: JSONObject?, replayable: Boolean): RequestBody {
        val json = (body ?: JSONObject()).toString()
        return object : RequestBody() {
            override fun contentType() = JSON
            override fun contentLength() = json.toByteArray(Charsets.UTF_8).size.toLong()
            override fun isOneShot() = !replayable
            override fun writeTo(sink: BufferedSink) { sink.writeUtf8(json) }
        }
    }

    private fun readResponse(response: Response): JSONObject {
        val raw = response.body?.string().orEmpty()
        if (raw.length > MAX_RESPONSE_CHARS) {
            throw CloudflareBackendException(502, "response_too_large", "Aaris Remote returned an invalid response.")
        }
        val root = if (raw.isBlank()) JSONObject() else runCatching { JSONObject(raw) }.getOrElse {
            if (response.isSuccessful) {
                throw CloudflareBackendException(502, "invalid_response", "Aaris Remote returned invalid data.")
            }
            JSONObject()
        }
        if (!response.isSuccessful) {
            throw CloudflareBackendException(
                response.code, root.optString("error", "backend_error"),
                root.optString("message", "Aaris Remote request failed.")
            )
        }
        return root
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
        private const val MAX_RESPONSE_CHARS = 1024 * 1024
        private val SESSION_ACTION = Regex("^/v1/sessions/[a-f0-9]{64}/(?:state|close|ice)$")
        private val CONTROLLER_TOKEN = Regex("^[A-Za-z0-9_-]{43,128}$")

        private fun replayable(method: String, path: String, body: JSONObject?): Boolean =
            method == "GET" || method == "HEAD" || (method == "POST" && (
                SESSION_ACTION.matches(path) ||
                    (path == "/v1/sessions/redeem" &&
                        body?.optString("controllerToken")?.matches(CONTROLLER_TOKEN) == true)
                ))

        private fun recoverable(error: IOException): Boolean =
            error !is SSLException && error !is ProtocolException &&
                (error !is InterruptedIOException || error is SocketTimeoutException)

        private fun HttpUrl.sameOrigin(other: HttpUrl): Boolean =
            scheme == other.scheme && host == other.host && port == other.port
    }
}
