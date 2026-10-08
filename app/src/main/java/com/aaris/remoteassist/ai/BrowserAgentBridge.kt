package com.aaris.remoteassist.ai

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.backend.CloudflareBackend
import com.aaris.remoteassist.capture.AiSnapshotProvider
import com.aaris.remoteassist.capture.ScreenCaptureTrack
import com.aaris.remoteassist.session.LiveLease
import com.aaris.remoteassist.session.SessionRuntime
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

/** Independent HTTPS observation/control lane over the existing projection and executor. */
class BrowserAgentBridge(
    private val context: Context,
    private val sessionId: String,
    track: ScreenCaptureTrack,
    private val acquireLease: () -> LiveLease?,
    private val isActive: () -> Boolean,
    private val onClosed: () -> Unit
) : AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val snapshots = AiSnapshotProvider(track)
    private val engine = AiObservationEngine(context, snapshots)
    private val mutex = Mutex()
    private val nonce = UUID.randomUUID().toString()
    private val outcomes = linkedMapOf<String, Pair<String, JSONObject>>()
    private var socket: WebSocket? = null
    private var closed = false
    private var reconnect: Job? = null
    private var chatCheck: Job? = null
    private var latest: JSONObject? = null
    private var retry = 0
    private var lastChatText = ""
    private var chatExecuting = false
    private val changedCallback: () -> Unit = { engine.changed(); inspectChat() }

    fun start() {
        BrowserLinkRuntime.screenChanged = changedCallback
        connect()
    }
    private fun connect() {
        if (closed || !isActive()) return
        val request = CloudflareBackend.socketRequest(context, sessionId, 0).newBuilder()
            .url(CloudflareBackend.BASE_URL.replaceFirst("https://", "wss://") + "/v1/sessions/$sessionId/agent-socket").build()
        socket = CloudflareBackend.httpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) { scope.launch {
                if (closed || socket !== ws) return@launch
                retry = 0
                mutex.withLock {
                    runCatching { observeAndPublish() }.onFailure { runCatching { publish(failure("CAPTURE_UNAVAILABLE", false)) } }
                }
            } }
            override fun onMessage(ws: WebSocket, text: String) { scope.launch {
                if (closed || socket !== ws) return@launch
                val message = runCatching { JSONObject(text) }.getOrNull() ?: return@launch
                if (message.optString("kind") == "session" && message.optJSONObject("session")?.optString("state") == "CLOSED") { onClosed(); return@launch }
                if (message.optString("kind") != "agent_request") return@launch
                mutex.withLock {
                    val id = message.optString("requestId")
                    if (message.optLong("expiresAtMs") <= System.currentTimeMillis()) return@withLock
                    // Atomic server grant fences old browsers/replaced sockets. Never retry an action.
                    val granted = runCatching { request("agent-start", JSONObject().put("requestId", id)) }.getOrNull()
                    if (granted?.optBoolean("ok") != true || !isActive()) return@withLock
                    val result = runCatching {
                        if (message.optString("operation") == "observe") observe() else execute(message.getJSONObject("args"))
                    }.getOrElse { failure("ACTION_FAILED", null) }
                    runCatching { publish(result, id) }
                }
            } }
            override fun onFailure(ws: WebSocket, error: Throwable, response: Response?) = lost(ws)
            override fun onClosed(ws: WebSocket, code: Int, reason: String) = lost(ws)
        })
    }
    private fun lost(ws: WebSocket) { scope.launch {
        if (closed || socket !== ws) return@launch
        socket = null; reconnect?.cancel()
        reconnect = scope.launch { delay(minOf(8000L, 500L shl minOf(retry++, 4))); connect() }
    } }
    private suspend fun request(action: String, body: JSONObject): JSONObject = withContext(Dispatchers.IO) {
        CloudflareBackend.sessionRequest(context, sessionId, "POST", action, body)
    }
    private suspend fun publish(result: JSONObject, id: String? = null) {
        request("agent-publish", JSONObject().put("result", result).apply { id?.let { put("requestId", it) } })
    }
    private suspend fun observe(): JSONObject {
        // Preserve the target screenshot while the owner reads the AI's response.
        val currentPackage = AssistAccessibilityService.aiSnapshot()?.packageName
        val cached = latest
        if (currentPackage in BrowserAgentCommand.chatPackages && cached != null &&
            engine.ledger.valid(cached.optString("observationId"), cached.optLong("screenVersion"), SystemClock.elapsedRealtime())) {
            return JSONObject(cached.toString()).apply {
                put("observationContext", "held-target-while-ai-chat")
                put("note", "The owner is reading an AI chat. This image holds the last observed target screen. A target action resumes that app and rechecks its pixels before tapping.")
            }
        }
        val result = engine.observe().put("commandNonce", nonce)
        if (result.has("observationId")) latest = JSONObject(result.toString())
        return result
    }
    private suspend fun observeAndPublish() {
        val result = observe()
        if (result.has("observationId")) acquireLease()
        publish(result)
    }
    private suspend fun execute(raw: JSONObject): JSONObject {
        val args = runCatching { BrowserAgentCommand.validate(JSONObject(raw.toString()), nonce) }.getOrElse { return failure("INVALID_COMMAND", false) }
        val id = args.getString("actionId"); val digest = args.toString()
        outcomes[id]?.let { return if (it.first == digest) JSONObject(it.second.toString()) else failure("ACTION_ID_CONFLICT", false) }
        val action = args.getString("action")
        val seen = latest ?: return finish(id, digest, false, "OBSERVATION_REQUIRED")
        if (!engine.ledger.valid(args.getString("observationId"), args.getLong("screenVersion"), SystemClock.elapsedRealtime())) return finish(id, digest, false, "STALE_SCREEN")
        val lease = acquireLease() ?: return finish(id, digest, false, "CONTROL_UNAVAILABLE")
        var resumed = false
        // The owner may read ChatGPT on this same phone while its cloud browser
        // acts on the held target image. HTTPS actions need the same guarded
        // resume as the visible-chat adapter; otherwise only Home can work.
        val foregroundPackage = AssistAccessibilityService.aiSnapshot()?.packageName
        if (BrowserAgentCommand.requiresTargetResume(action, foregroundPackage)) {
            val target = seen.optString("currentPackage")
            if (target.isBlank() || target == context.packageName || target in BrowserAgentCommand.chatPackages) return finish(id, digest, false, "TARGET_SCREEN_REQUIRED")
            val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            val homePackage = context.packageManager.resolveActivity(home, 0)?.activityInfo?.packageName
            resumed = if (target == homePackage) dispatch(JSONObject().put("action", "home"), lease, 1) == true else AiAppLauncher.launch(context, target)
            if (!resumed) return finish(id, digest, false, "TARGET_APP_UNAVAILABLE")
            delay(350)
        }
        val validation = engine.validate(args, exactCoordinates = true, allowWindowResume = resumed)
        if (validation.error != null) return finish(id, digest, false, validation.error)
        engine.ledger.consume()
        outcomes[id] = digest to failure("OUTCOME_UNKNOWN", null)
        while (outcomes.size > 64) outcomes.remove(outcomes.keys.first())
        val valid = { isActive() && validation.stillValid() && SessionRuntime.isAuthorized(lease.sessionId, lease.leaseSecret, lease.displayGeneration) }
        val applied = if (action == "open_app") valid() && AiAppLauncher.launch(context, args.getString("app")) else dispatch(args, lease, if (resumed) 2 else 1, valid)
        return finish(id, digest, applied)
    }
    private suspend fun finish(id: String, digest: String, applied: Boolean?, reason: String? = null): JSONObject {
        engine.invalidate(); latest = null
        val result = runCatching { engine.observe() }.getOrElse { failure("CAPTURE_UNAVAILABLE", applied) }
            .put("commandNonce", nonce).put("actionId", id).put("applied", applied ?: JSONObject.NULL)
        if (reason != null) result.put("error", reason)
        if (result.has("observationId")) latest = JSONObject(result.toString()).apply { remove("error"); remove("actionId"); remove("applied") }
        outcomes[id] = digest to JSONObject(result.toString())
        while (outcomes.size > 64) outcomes.remove(outcomes.keys.first())
        return result
    }
    private suspend fun dispatch(args: JSONObject, lease: LiveLease, sequence: Long, valid: () -> Boolean = { isActive() && SessionRuntime.isAuthorized(lease.sessionId, lease.leaseSecret, lease.displayGeneration) }): Boolean? {
        val (width, height) = engine.geometry()
        val done = CompletableDeferred<Boolean>()
        AssistAccessibilityService.dispatch(AiActionTranslator.translate(args, lease, sequence, width, height), precondition = valid) { done.complete(it) }
        return withTimeoutOrNull(3500) { done.await() }
    }
    private fun inspectChat() {
        if (closed || chatExecuting) return
        chatCheck?.cancel()
        chatCheck = scope.launch {
            delay(1200)
            val candidate = AssistAccessibilityService.browserAgentReply() ?: return@launch
            val text = candidate.second
            if (text == lastChatText) return@launch
            val args = BrowserAgentCommand.parse(text, nonce, true) ?: return@launch
            delay(300)
            if (AssistAccessibilityService.browserAgentReply() != candidate) return@launch
            lastChatText = text
            chatExecuting = true
            try { mutex.withLock {
                if (!isActive()) return@withLock
                val result = runCatching { execute(args) }.getOrElse { failure("ACTION_FAILED", null) }
                runCatching { publish(result) }
                BrowserLinkRuntime.update(if (result.optBoolean("applied") && result.has("observationId")) "AI command applied • next screenshot ready" else "AI command paused • ${result.optString("error", "inspect the result")}")
                // Return to the AI after caching the target screen; hidden chat windows cannot be read.
                if (isActive()) AiAppLauncher.launch(context, candidate.first)
            } } finally { chatExecuting = false }
        }
    }
    private fun failure(error: String, applied: Boolean?) = JSONObject().put("error", error).put("applied", applied ?: JSONObject.NULL)
    override fun close() {
        closed = true
        if (BrowserLinkRuntime.screenChanged === changedCallback) BrowserLinkRuntime.screenChanged = null
        socket?.cancel(); socket = null; scope.cancel(); snapshots.close(); engine.invalidate(); latest = null; outcomes.clear()
    }
}
