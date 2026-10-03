package com.aaris.remoteassist.ai

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.capture.AiSnapshotProvider
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.ProjectionGrant
import com.aaris.remoteassist.capture.ScreenCaptureTrack
import com.aaris.remoteassist.session.LiveLease
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionRuntime
import com.aaris.remoteassist.ui.MainActivity
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

/** Explicitly started, visible MediaProjection owner. A process restart always needs new consent. */
class AiConnectorService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val backend = AiConnectorBackend()
    private var credential: AiCredential? = null
    private var capture: ScreenCaptureTrack? = null
    private var snapshots: AiSnapshotProvider? = null
    private var observations: AiObservationEngine? = null
    private var socket: WebSocket? = null
    private var lease: LiveLease? = null
    private var reconnectJob: Job? = null
    private var heartbeatJob: Job? = null
    private var stopping = false
    private var busy = false
    private var retry = 0
    private var lastAckMs = 0L
    private var sequence = 0L
    private var registeredNetworkCallback = false
    private val runId = UUID.randomUUID().toString()
    private val ownerId = "ai:$runId"
    private val outcomes = LinkedHashMap<String, JSONObject>()
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { scope.launch { if (socket == null && credential != null && !stopping) scheduleReconnect(true) } }
    }

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (stopping) { stopSelf(); return START_NOT_STICKY }
        if (intent?.action == ACTION_STOP) { stopNow(); return START_NOT_STICKY }
        if (intent?.action != ACTION_START || capture != null) return START_NOT_STICKY
        try {
            check(AssistAccessibilityService.isConnected()) { "Turn on Accessibility and try again" }
            check(SessionCoordinator.reserveAi(ownerId)) { "End the current remote session first" }
            val data = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(EXTRA_DATA, Intent::class.java) else {
                @Suppress("DEPRECATION") intent.getParcelableExtra<Intent>(EXTRA_DATA)
            }
            check(intent.getIntExtra(EXTRA_RESULT, 0) == Activity.RESULT_OK && data != null) { "Screen sharing permission is required" }
            credential = checkNotNull(AiConnectorStore(this).load()) { "Create an AI link first" }
            foreground()
            capture = ScreenCaptureTrack(this, ProjectionGrant(ownerId, Activity.RESULT_OK, data)) {
                scope.launch { stopNow("Screen sharing stopped") }
            }
            snapshots = AiSnapshotProvider(checkNotNull(capture))
            observations = AiObservationEngine(this, checkNotNull(snapshots))
            AiObservationSignals.changed = { observations?.changed() }
            capture?.start(profile())
            AiConnectorRuntime.update(AiConnectorState(true, false, "Connecting AI…"))
            getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(networkCallback)
            registeredNetworkCallback = true
            openSocket()
        } catch (error: Exception) { stopNow(error.message ?: "Could not start AI sharing") }
        return START_NOT_STICKY
    }

    private fun profile(): CaptureProfile {
        val tier = if (CaptureProfile.recommendedTier(this) == CaptureTier.LOW) CaptureTier.BALANCED else CaptureTier.STANDARD
        // Capture remains live, but expensive conversion and uploads happen only on demand.
        return CaptureProfile.current(this, tier).copy(fps = 8, motionFps = 8)
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        observations?.invalidate()
        capture?.update(profile())
    }

    private fun openSocket() {
        if (stopping || socket != null) return
        val value = credential ?: return
        lastAckMs = SystemClock.elapsedRealtime()
        socket = backend.connect(value, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { scope.launch {
                if (socket !== webSocket || stopping) { webSocket.cancel(); return@launch }
                webSocket.send(JSONObject().put("type", "ready").put("runId", runId).toString())
                heartbeatJob?.cancel()
                heartbeatJob = scope.launch {
                    while (isActive && socket === webSocket) {
                        delay(12_000)
                        if (SystemClock.elapsedRealtime() - lastAckMs > 30_000 ||
                            !webSocket.send("{\"type\":\"heartbeat\"}")) { disconnected(webSocket); break }
                        if (!AssistAccessibilityService.isConnected()) { stopNow("Accessibility disconnected"); break }
                    }
                }
            } }
            override fun onMessage(webSocket: WebSocket, text: String) { scope.launch {
                if (socket !== webSocket || stopping || text.length > 16_384) return@launch
                val packet = runCatching { JSONObject(text) }.getOrNull() ?: return@launch
                when (packet.optString("type")) {
                    "ack" -> {
                        lastAckMs = SystemClock.elapsedRealtime(); retry = 0
                        val current = lease
                        lease = if (current == null) SessionCoordinator.activateAi(ownerId)
                            else SessionRuntime.renew(ownerId, current.leaseSecret) ?: SessionCoordinator.activateAi(ownerId)
                        AiConnectorRuntime.update(AiConnectorState(true, true, "AI connected • tap STOP any time"))
                    }
                    "request" -> handleRequest(webSocket, packet)
                }
            } }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { scope.launch {
                if (response?.code in listOf(401, 403)) stopNow("AI link expired. Connect again.") else disconnected(webSocket)
            } }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { scope.launch {
                if (code == 4003) stopNow("AI link stopped or expired") else disconnected(webSocket)
            } }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
        })
        // Also bounds sockets that never reach onOpen.
        val openingSocket = socket
        scope.launch { delay(15_000); if (!stopping && socket === openingSocket && !AiConnectorRuntime.state.online) openingSocket?.let(::disconnected) }
    }
    private fun disconnected(ws: WebSocket) {
        if (socket !== ws || stopping) return
        socket = null; ws.cancel(); heartbeatJob?.cancel(); lease = null
        SessionCoordinator.suspendAi(ownerId); observations?.invalidate()
        AiConnectorRuntime.update(AiConnectorState(true, false, "AI reconnecting…"))
        scheduleReconnect(false)
    }
    private fun scheduleReconnect(immediate: Boolean) {
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            if (!immediate) delay((1000L shl retry.coerceAtMost(5)).coerceAtMost(30_000) + kotlin.random.Random.nextLong(250))
            retry++; openSocket()
        }
    }

    private suspend fun handleRequest(ws: WebSocket, packet: JSONObject) {
        val requestId = packet.optString("requestId")
        if (requestId.length !in 16..96 || packet.optString("runId") != runId) return
        fun send(result: JSONObject) { if (socket === ws && !stopping) ws.send(JSONObject().put("type", "result").put("requestId", requestId).put("result", result).toString()) }
        if (busy) { send(failure("BUSY")); return }
        busy = true
        var actionId: String? = null
        var applied: Boolean? = false
        var dispatched = false
        try {
            val result = withTimeout(packet.optLong("timeoutMs", 18_000).coerceIn(1000, 18_000)) {
                val engine = checkNotNull(observations)
                val args = packet.optJSONObject("arguments") ?: JSONObject()
                when (packet.optString("tool")) {
                    "phone_observe" -> engine.observe(args.optString("quality") == "detail")
                    "phone_action" -> {
                        val id = args.getString("actionId").also { require(it.matches(Regex("[a-zA-Z0-9_-]{8,96}"))) }
                        actionId = id
                        outcomes[id]?.let { return@withTimeout JSONObject(it.toString()).put("replayed", true).put("needsObservation", true) }
                        if (!engine.validate(args)) return@withTimeout engine.observe().put("error", "STALE_SCREEN").put("applied", false).put("actionId", id)
                        val currentLease = lease ?: return@withTimeout failure("NOT_CONNECTED")
                        val (width, height) = engine.geometry()
                        val command = AiActionTranslator.translate(args, currentLease, ++sequence, width, height)
                        val expectedVersion = engine.ledger.version
                        engine.ledger.consume() // Even a refused/no-op action consumes its observation.
                        outcomes[id] = failure("OUTCOME_UNKNOWN", null)
                        dispatched = true; applied = null
                        val done = CompletableDeferred<Boolean>()
                        val expiresAt = SystemClock.elapsedRealtime() + 1500
                        AssistAccessibilityService.dispatch(command, precondition = {
                            !stopping && socket === ws && engine.ledger.version == expectedVersion &&
                                SystemClock.elapsedRealtime() <= expiresAt &&
                                CaptureProfile.current(this@AiConnectorService, CaptureTier.BALANCED).let {
                                    it.displayWidthPx == width && it.displayHeightPx == height
                                }
                        }) { done.complete(it) }
                        applied = withTimeout(3500) { done.await() }
                        engine.invalidate()
                        val image = engine.observe()
                        image.put("applied", applied).put("actionId", id)
                        if (applied != true && !image.has("error")) image.put("error", "ACTION_NOT_APPLIED")
                        image
                    }
                    else -> failure("UNKNOWN_TOOL")
                }
            }
            if (actionId != null && dispatched) remember(checkNotNull(actionId), result)
            send(result)
        } catch (error: Exception) {
            val result = failure(if (dispatched) "ACTION_RESULT_REQUIRES_OBSERVATION" else "OBSERVATION_UNAVAILABLE", applied)
            actionId?.let { result.put("actionId", it); if (dispatched) remember(it, result) }
            if (error is CancellationException && stopping) throw error
            send(result)
        } finally { busy = false }
    }
    private fun remember(id: String, result: JSONObject) {
        outcomes[id] = JSONObject().put("actionId", id).put("applied", result.opt("applied") ?: JSONObject.NULL)
            .apply { if (result.has("error")) put("error", result.get("error")) }
        while (outcomes.size > 128) outcomes.remove(outcomes.keys.first())
    }
    private fun failure(code: String, applied: Boolean? = false) = JSONObject().put("error", code).put("applied", applied ?: JSONObject.NULL)

    private fun foreground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "AI phone control", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 72, Intent(this, AiConnectorService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 73, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notice = Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("AI can see and control this phone").setContentText("Tap STOP to end sharing")
            .setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null, "STOP", stop).build()).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(7201, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        else startForeground(7201, notice)
    }
    private fun stopNow(message: String = "AI control stopped") {
        if (stopping) return
        stopping = true
        SessionCoordinator.suspendAi(ownerId) // Invalidate queued gestures immediately, before network cleanup.
        AiConnectorRuntime.update(AiConnectorState(message = message))
        socket?.cancel(); socket = null
        credential?.let { value ->
            // Bounded cleanup outlives the service, while local capture/control stop immediately.
            CoroutineScope(Dispatchers.IO).launch {
                val cleanup = AiConnectorBackend()
                try { runCatching { cleanup.revoke(value) } } finally { cleanup.close() }
            }
        }
        // Network revoke is best effort; local stop never waits for it.
        releaseCapture()
        stopSelf()
    }
    private fun releaseCapture() {
        AiObservationSignals.changed = null
        observations?.invalidate(); observations = null
        snapshots?.close(); snapshots = null
        capture?.close(); capture = null
        lease = null; SessionCoordinator.releaseAi(ownerId)
    }
    override fun onDestroy() {
        stopping = true; socket?.cancel(); releaseCapture()
        if (registeredNetworkCallback) runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback) }
        if (AiConnectorRuntime.state.active) AiConnectorRuntime.update(AiConnectorState())
        scope.cancel(); backend.close(); stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
    companion object {
        const val ACTION_START = "com.aaris.remoteassist.ai.START"
        const val ACTION_STOP = "com.aaris.remoteassist.ai.STOP"
        const val EXTRA_DATA = "ai_projection_data"
        const val EXTRA_RESULT = "ai_projection_result"
        private const val CHANNEL = "ai_control"
        fun stop(context: Context) { context.startService(Intent(context, AiConnectorService::class.java).setAction(ACTION_STOP)) }
    }
}
