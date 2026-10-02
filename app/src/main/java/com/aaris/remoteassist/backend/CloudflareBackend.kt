package com.aaris.remoteassist.backend

import android.content.Context
import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

internal class CloudflareBackendException(
    val statusCode: Int,
    val backendCode: String,
    message: String
) : IOException("$backendCode: $message")

internal object CloudflareBackend {
    const val BASE_URL =
        "https://aaris-remote-core.aaris-remote-wk3548.workers.dev"

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(6, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .writeTimeout(8, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    private val jsonMediaType =
        "application/json; charset=utf-8".toMediaType()

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
    ): JSONObject = execute(
        method = method,
        url = BASE_URL + path,
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
        return execute(
            method = method,
            url = "$BASE_URL/v1/sessions/$sessionId$suffix",
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
        val wsBase = BASE_URL.replaceFirst("https://", "wss://")
        return Request.Builder()
            .url(
                "$wsBase/v1/sessions/$sessionId/socket" +
                    "?after=${afterSequence.coerceAtLeast(0L)}"
            )
            .header("Authorization", "Bearer $token")
            .header("Cache-Control", "no-store")
            .build()
    }

    private fun execute(
        method: String,
        url: String,
        token: String?,
        body: JSONObject?
    ): JSONObject {
        val requestBody = if (method.equals("GET", ignoreCase = true)) {
            null
        } else {
            (body ?: JSONObject())
                .toString()
                .toRequestBody(jsonMediaType)
        }

        val builder = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .header("Cache-Control", "no-store")

        if (!token.isNullOrBlank()) {
            builder.header("Authorization", "Bearer $token")
        }

        builder.method(method.uppercase(), requestBody)

        httpClient.newCall(builder.build()).execute().use { response ->
            val raw = response.body?.string().orEmpty()
            if (raw.length > MAX_RESPONSE_CHARS) {
                throw CloudflareBackendException(
                    502,
                    "response_too_large",
                    "Aaris Remote returned an invalid response."
                )
            }

            val root = if (raw.isBlank()) {
                JSONObject()
            } else {
                runCatching { JSONObject(raw) }.getOrElse {
                    if (response.isSuccessful) {
                        throw CloudflareBackendException(
                            502,
                            "invalid_response",
                            "Aaris Remote returned invalid data."
                        )
                    }
                    JSONObject()
                }
            }

            if (!response.isSuccessful) {
                throw CloudflareBackendException(
                    statusCode = response.code,
                    backendCode = root.optString("error", "backend_error"),
                    message = root.optString(
                        "message",
                        "Aaris Remote request failed."
                    )
                )
            }
            return root
        }
    }

    private val SESSION_ID = Regex("^[a-f0-9]{64}$")
    private const val MAX_RESPONSE_CHARS = 1024 * 1024
}
