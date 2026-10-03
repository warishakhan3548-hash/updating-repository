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
import com.aaris.remoteassist.webrtc.WebRtcRuntime
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
import kotlinx.coroutines.withContext
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
    private var defaultNetwork: Network? = null
    private var starting = false
    private val runId = UUID.randomUUID().toString()
    private val ownerId = "ai:$runId"
    private val outcomes = LinkedHashMap<String, JSONObject>()
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { scope.launch {
            if (stopping || capture == null) return@launch
            if (defaultNetwork != network) socket?.let(::disconnected)
            defaultNetwork = network
            if (socket == null && credential != null) scheduleReconnect(true)
        } }
        override fun onLost(network: Network) { scope.launch {
            if (defaultNetwork != network || stopping) return@launch
            defaultNetwork = null
            socket?.let(::disconnected)
        } }
    }

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (stopping) { stopSelf(); return START_NOT_STICKY }
        if (intent?.action == ACTION_STOP) { stopNow(); return START_NOT_STICKY }
        if (intent?.action != ACTION_START || capture != null || starting) return START_NOT_STICKY
        try {
            check(AssistAccessibilityService.isConnected()) { "Turn on Accessibility and try again" }
            check(SessionCoordinator.reserveAi(ownerId)) { "End the current remote session first" }
            val data = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(EXTRA_DATA, Intent::class.java) else {
                @Suppress("DEPRECATION") intent.getParcelableExtra<Intent>(EXTRA_DATA)
            }
            check(intent.getIntExtra(EXTRA_RESULT, 0) == Activity.RESULT_OK && data != null) { "Screen sharing permission is required" }
            // Promote immediately after consent, before Keystore/native startup.
            // These can be slow on the very first run of an older phone.
            foreground()
            starting = true
            AiConnectorRuntime.update(AiConnectorState(true, false, "Starting screen sharing…"))
            scope.launch {
                try {
                    credential = withContext(Dispatchers.IO) {
                        val saved = checkNotNull(AiConnectorStore(this@AiConnectorService).load()) { "Create an AI link first" }
                        WebRtcRuntime.initialize(applicationContext)
                        saved
                    }
                    if (stopping) return@launch
                    capture = ScreenCaptureTrack(this@AiConnectorService, ProjectionGrant(ownerId, Activity.RESULT_OK, data)) {
                        scope.launch { stopNow("Screen sharing stopped. Tap Connect Phone with AI to resume.") }
                    }
                    snapshots = AiSnapshotProvider(checkNotNull(capture))
                    observations = AiObservationEngine(this@AiConnectorService, checkNotNull(snapshots))
                    AiObservationSignals.changed = { observations?.changed() }
                    capture?.start(profile())
                    AiConnectorRuntime.update(AiConnectorState(true, false, "Screen sharing started • connecting AI…"))
                    val networkManager = getSystemService(ConnectivityManager::class.java)
                    defaultNetwork = networkManager.activeNetwork
                    networkManager.registerDefaultNetworkCallback(networkCallback)
                    registeredNetworkCallback = true
                    openSocket()
                } catch (error: CancellationException) { throw error }
                catch (error: Exception) { startFailed(error) }
                catch (error: LinkageError) { startFailed(error) }
                finally { starting = false }
            }
        } catch (error: Exception) { startFailed(error) }
        return START_NOT_STICKY
    }

    private fun startFailed(error: Throwable) {
        val hint = when (error) {
            is SecurityException -> "Screen sharing permission was not accepted. Connect again and allow full-screen sharing."
            is LinkageError -> "Screen capture could not load. Install the latest Aaris Remote build."
            else -> "AI sharing could not start (${error.javaClass.simpleName}). Tap Connect Phone with AI to retry."
        }
        stopNow(hint)
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
                if (socket !== webSocket || stopping) return@launch
                if (response?.code in listOf(401, 403)) stopNow("AI link expired. Connect again.") else disconnected(webSocket)
            } }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { scope.launch {
                if (socket !== webSocket || stopping) return@launch
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
        AiConnectorRuntime.update(AiConnectorState(true, false, "AI reconnecting over Wi-Fi or mobile internet…"))
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
                        val validation = engine.validate(args)
                        if (validation.error != null) {
                            val code = if (validation.error in setOf("LOCAL_ONLY_SCREEN", "DEVICE_LOCKED_OR_ACCESSIBILITY_OFF", "FOCUSED_FIELD_REQUIRED"))
                                validation.error else "STALE_SCREEN"
                            return@withTimeout engine.observe().put("error", code)
                                .put("reason", validation.error).put("applied", false).put("actionId", id)
                        }
                        val currentLease = lease ?: return@withTimeout failure("NOT_CONNECTED")
                        val (width, height) = engine.geometry()
                        val action = args.getString("action")
                        engine.ledger.consume() // Even a refused/no-op action consumes its observation.
                        outcomes[id] = failure("OUTCOME_UNKNOWN", null)
                        dispatched = true; applied = null
                        val expiresAt = SystemClock.elapsedRealtime() + 1500
                        val preconditionValid = {
                            !stopping && socket === ws && validation.stillValid() &&
                                SystemClock.elapsedRealtime() <= expiresAt &&
                                SessionRuntime.isAuthorized(
                                    currentLease.sessionId,
                                    currentLease.leaseSecret,
                                    currentLease.displayGeneration
                                ) &&
                                CaptureProfile.current(this@AiConnectorService, CaptureTier.BALANCED).let {
                                    it.displayWidthPx == width && it.displayHeightPx == height
                                }
                        }
                        applied = if (action == "open_app") {
                            preconditionValid() && AiAppLauncher.launch(
                                this@AiConnectorService,
                                args.getString("app")
                            )
                        } else {
                            val command = AiActionTranslator.translate(
                                args,
                                currentLease,
                                ++sequence,
                                width,
                                height
                            )
                            val done = CompletableDeferred<Boolean>()
                            AssistAccessibilityService.dispatch(
                                command,
                                precondition = preconditionValid
                            ) { done.complete(it) }
                            withTimeout(3500) { done.await() }
                        }
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
    private fun stopNow(message: String = "AI control stopped • your saved link can be reused") {
        if (stopping) return
        stopping = true
        SessionCoordinator.suspendAi(ownerId) // Invalidate queued gestures immediately, before network cleanup.
        AiConnectorRuntime.update(AiConnectorState(message = message))
        socket?.let { ws ->
            ws.send(JSONObject().put("type", "stopped").put("runId", runId).toString())
            ws.close(1000, "Stopped on phone")
        }
        socket = null
        credential?.let { value ->
            // Bounded cleanup outlives the service, while local capture/control stop immediately.
            CoroutineScope(Dispatchers.IO).launch {
                val cleanup = AiConnectorBackend()
                try { runCatching { cleanup.pause(value, runId) } } finally { cleanup.close() }
            }
        }
        // The run-scoped pause cannot disable a newer service. Keep the MCP
        // credential so clients can report stopped instead of authentication failure.
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
