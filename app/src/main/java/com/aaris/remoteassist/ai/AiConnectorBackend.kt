package com.aaris.remoteassist.ai

import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

class AiConnectorBackend internal constructor(private val client: OkHttpClient) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    constructor() : this(OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS).callTimeout(15, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS).build())
    suspend fun register(value: AiCredential) = withContext(Dispatchers.IO) {
        check(!closed.get()) { "AI connection is closed" }
        val body = JSONObject().put("clientToken", value.clientToken).toString()
        client.newCall(request(value, "register").post(body.toRequestBody(JSON)).build()).execute().use {
            check(it.isSuccessful) { "Could not create AI link (${it.code}). Try again." }
        }
    }
    suspend fun revoke(value: AiCredential) = withContext(Dispatchers.IO) {
        check(!closed.get()) { "AI connection is closed" }
        client.newCall(request(value, "revoke").post(JSONObject().put("clientToken", value.clientToken).toString().toRequestBody(JSON)).build()).execute().close()
    }
    suspend fun pause(value: AiCredential, runId: String) = withContext(Dispatchers.IO) {
        check(!closed.get()) { "AI connection is closed" }
        val body = JSONObject().put("runId", runId).toString()
        client.newCall(request(value, "pause").post(body.toRequestBody(JSON)).build()).execute().close()
    }
    fun connect(value: AiCredential, listener: WebSocketListener): WebSocket {
        check(!closed.get()) { "AI connection is closed" }
        return client.newWebSocket(request(value, "socket").build(), listener)
    }
    private fun request(value: AiCredential, action: String) = Request.Builder()
        .url("$BASE_URL/v1/connectors/${value.connectorId}/$action")
        .header("User-Agent", "AarisRemote/${com.aaris.remoteassist.BuildConfig.VERSION_NAME}")
        .header("Authorization", "Bearer ${value.deviceToken}")
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        // SSL close can send close_notify, so evictAll is NETWORK I/O too.
        // Activity finally/service onDestroy may run on Main and their scopes
        // may already be cancelled. Cleanup must outlive those scopes.
        cleanupScope.launch {
            try { runCatching { client.dispatcher.cancelAll() } }
            finally {
                try { runCatching { client.connectionPool.evictAll() } }
                finally { client.dispatcher.executorService.shutdown() }
            }
        }
    }
    companion object {
        const val BASE_URL = "https://aaris-phone-mcp.aaris-remote-wk3548.workers.dev"
        private val JSON = "application/json".toMediaType()
        private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}
