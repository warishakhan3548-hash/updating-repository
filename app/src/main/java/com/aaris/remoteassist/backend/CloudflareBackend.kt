package com.aaris.remoteassist.backend

import android.content.Context
import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

internal class CloudflareBackendException(
    val statusCode: Int,
    val backendCode: String,
    message: String
) : IOException("$backendCode: $message")

internal object CloudflareBackend {
    const val BASE_URL =
        "https://aaris-remote-ice.aaris-remote-wk3548.workers.dev"
    private const val FALLBACK_URL = "https://aaris-remote-connect.pages.dev"

    private val transport = BackendTransport(OkHttpClient.Builder()
        .fastFallback(true)
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .writeTimeout(8, TimeUnit.SECONDS)
        .callTimeout(12, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build(), listOf(BASE_URL.toHttpUrl(), FALLBACK_URL.toHttpUrl()))

    val httpClient: OkHttpClient get() = transport.httpClient

    fun socketConnected(request: Request) = transport.connected(request.url)

    fun socketFailed(request: Request, error: Throwable) {
        if (error is IOException) transport.connectionFailed(request.url, error)
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(
            "cloudflare_sessions",
            Context.MODE_PRIVATE
        )

    fun rememberToken(context: Context, sessionId: String, token: String) {
        require(sessionId.matches(SESSION_ID))
        require(token.isNotBlank())
        prefs(context).edit()
            .putString("token_$sessionId", token)
            .apply()
    }

    fun token(context: Context, sessionId: String): String? =
        prefs(context)
            .getString("token_$sessionId", null)
            ?.takeIf(String::isNotBlank)

    fun forgetToken(context: Context, sessionId: String) {
        prefs(context).edit()
            .remove("token_$sessionId")
            .apply()
    }

    fun publicRequest(
        method: String,
        path: String,
        body: JSONObject? = null
    ): JSONObject = transport.execute(
        method = method,
        path = path,
        token = null,
        body = body
    )

    fun sessionRequest(
        context: Context,
        sessionId: String,
        method: String,
        action: String = "",
        body: JSONObject? = null
    ): JSONObject {
        require(sessionId.matches(SESSION_ID))
        val token = token(context, sessionId)
            ?: throw CloudflareBackendException(
                401,
                "missing_session_token",
                "Session credentials are missing."
            )
        val suffix = if (action.isBlank()) "" else "/$action"
        return transport.execute(
            method = method,
            path = "/v1/sessions/$sessionId$suffix",
            token = token,
            body = body
        )
    }

    fun socketRequest(
        context: Context,
        sessionId: String,
        afterSequence: Long
    ): Request {
        require(sessionId.matches(SESSION_ID))
        val token = token(context, sessionId)
            ?: throw CloudflareBackendException(
                401,
                "missing_session_token",
                "Session credentials are missing."
            )
        val wsBase = transport.currentOrigin().toString()
            .trimEnd('/').replaceFirst("https://", "wss://")
        return Request.Builder()
            .url(
                "$wsBase/v1/sessions/$sessionId/socket" +
                    "?after=${afterSequence.coerceAtLeast(0L)}"
            )
            .header("Authorization", "Bearer $token")
            .header("Cache-Control", "no-store")
            .build()
    }

    private val SESSION_ID = Regex("^[a-f0-9]{64}$")
}
