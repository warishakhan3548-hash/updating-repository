package com.aaris.remoteassist.ai

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

class AiConnectorBackend {
    private val client = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS).callTimeout(15, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS).build()
    suspend fun register(value: AiCredential) = withContext(Dispatchers.IO) {
        val body = JSONObject().put("clientToken", value.clientToken).toString()
        client.newCall(request(value, "register").post(body.toRequestBody(JSON)).build()).execute().use {
            check(it.isSuccessful) { "Could not create AI link (${it.code}). Try again." }
        }
    }
    suspend fun revoke(value: AiCredential) = withContext(Dispatchers.IO) {
        client.newCall(request(value, "revoke").post(JSONObject().put("clientToken", value.clientToken).toString().toRequestBody(JSON)).build()).execute().close()
    }
    fun connect(value: AiCredential, listener: WebSocketListener): WebSocket =
        client.newWebSocket(request(value, "socket").build(), listener)
    private fun request(value: AiCredential, action: String) = Request.Builder()
        .url("$BASE_URL/v1/connectors/${value.connectorId}/$action")
        .header("User-Agent", "AarisRemote/${com.aaris.remoteassist.BuildConfig.VERSION_NAME}")
        .header("Authorization", "Bearer ${value.deviceToken}")
    fun close() { client.dispatcher.cancelAll(); client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown() }
    companion object {
        const val BASE_URL = "https://aaris-phone-mcp.aaris-remote-wk3548.workers.dev"
        private val JSON = "application/json".toMediaType()
    }
}
