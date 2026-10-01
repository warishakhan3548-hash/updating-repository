package com.aaris.remoteassist.ui

import android.app.AlertDialog
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import com.aaris.remoteassist.pairing.BackendSessionCloser
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionState
import com.aaris.remoteassist.webrtc.ControllerWebRtcSession
import com.aaris.remoteassist.webrtc.RemoteGeometry
import com.aaris.remoteassist.webrtc.WebRtcRuntime
import java.io.Closeable
import kotlin.math.hypot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

class RemoteControlActivity : ComponentActivity() {
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Main
    )
    private val gateway by lazy {
        FirebasePairingGateway(this)
    }

    private lateinit var renderer: SurfaceViewRenderer
    private lateinit var statusPanel: LinearLayout
    private lateinit var statusProgress: ProgressBar
    private lateinit var status: TextView
    private lateinit var controlDock: LinearLayout
    private lateinit var controlHandle: Button

    @Volatile
    private var renderedFrameWidth = 0

    @Volatile
    private var renderedFrameHeight = 0

    private var observer: Closeable? = null
    private var rtcSession: ControllerWebRtcSession? = null
    private var remoteTrack: VideoTrack? = null
    private var sessionId: String? = null
    private var remoteGeometry: RemoteGeometry? = null
    private var disconnecting = false
    private var rtcConnected = false
    private var disconnectTimeout: Job? = null
    private var sessionDeadlineJob: Job? = null

    private var downX = 0f
    private var downY = 0f
    private var downAtMs = 0L

    private var twoFingerActive = false
    private var suppressSingleUp = false
    private var twoFingerStartedAtMs = 0L
    private var firstPointerId = MotionEvent.INVALID_POINTER_ID
    private var secondPointerId = MotionEvent.INVALID_POINTER_ID
    private var firstStartNx = 0f
    private var firstStartNy = 0f
    private var secondStartNx = 0f
    private var secondStartNy = 0f

    private val touchSlop by lazy {
        ViewConfiguration.get(this).scaledTouchSlop.toFloat()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )
        configureRemoteSystemBars()

        val requestedSessionId =
            intent.getStringExtra(EXTRA_SESSION_ID)
        if (requestedSessionId.isNullOrBlank()) {
            finish()
            return
        }
        sessionId = requestedSessionId

        WebRtcRuntime.initialize(this)
        setContentView(buildUi())
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    disconnect()
                }
            }
        )
        observe(requestedSessionId)
    }

    override fun onDestroy() {
        observer?.close()
        observer = null

        remoteTrack?.removeSink(renderer)
        remoteTrack = null

        disconnectTimeout?.cancel()
        disconnectTimeout = null

        sessionDeadlineJob?.cancel()
        sessionDeadlineJob = null

        rtcSession?.close()
        rtcSession = null

        if (::renderer.isInitialized) {
            renderer.release()
        }

        scope.cancel()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun configureRemoteSystemBars() {
        window.statusBarColor = Color.BLACK
        window.navigationBarColor = Color.BLACK

        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.setSystemBarsAppearance(
                0,
                android.view.WindowInsetsController
                    .APPEARANCE_LIGHT_STATUS_BARS or
                    android.view.WindowInsetsController
                        .APPEARANCE_LIGHT_NAVIGATION_BARS
            )
        } else {
            window.decorView.systemUiVisibility =
                window.decorView.systemUiVisibility and
                    View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv() and
                    View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR.inv()
        }
    }


    private fun observe(id: String) {
        observer = runCatching {
            gateway.observeSession(
                id,
                listener = { backend ->
                    runOnUiThread {
                        updateControllerDeadline(
                            id = id,
                            deadlineAtEpochMs = backend.deadlineAtEpochMs,
                            backendState = backend.state
                        )

                        when (backend.state) {
                            "PAIR_PENDING" ->
                                showStatus(
                                    "Waiting for your friend to tap START…"
                                )

                            "HOST_APPROVED" ->
                                showStatus(
                                    "Waiting for screen-share permission…"
                                )

                            "SCREEN_READY" -> {
                                val local =
                                    SessionCoordinator.snapshot()
                                val resumable =
                                    local.sessionId == id &&
                                        (
                                            local.state ==
                                                SessionState.PAIR_PENDING ||
                                                local.state ==
                                                    SessionState.HOST_APPROVED ||
                                                local.state ==
                                                    SessionState.SCREEN_CONSENT ||
                                                local.state ==
                                                    SessionState.CONNECTING
                                        )

                                if (!resumable && rtcSession == null) {
                                    showStatus(
                                        "Session was interrupted. Reconnect with a new code."
                                    )
                                    BackendSessionCloser.close(
                                        this@RemoteControlActivity,
                                        id
                                    )
                                    SessionCoordinator.close(id)
                                    finish()
                                    return@runOnUiThread
                                }

                                advanceControllerState(id)
                                ensureRtcStarted(id)
                            }

                            "LIVE" -> {
                                if (rtcSession == null) {
                                    showStatus(
                                        "Session was interrupted. Reconnect with a new code."
                                    )
                                    BackendSessionCloser.close(
                                        this@RemoteControlActivity,
                                        id
                                    )
                                    SessionCoordinator.close(id)
                                    return@runOnUiThread
                                }

                                runCatching {
                                    if (
                                        SessionCoordinator.snapshot().state ==
                                        SessionState.CONNECTING
                                    ) {
                                        SessionCoordinator.transition(
                                            id,
                                            SessionState.LIVE
                                        )
                                    }
                                }

                                if (remoteTrack == null) {
                                    showStatus(
                                        "Connected • waiting for video…"
                                    )
                                } else {
                                    statusPanel.visibility = View.GONE
                                }
                            }

                            "CLOSED" -> {
                                SessionCoordinator.close(id)
                                rtcSession?.close()
                                rtcSession = null
                                showStatus("Session ended")
                                finish()
                            }
                        }
                    }
                },
                onError = {
                    runOnUiThread {
                        if (!disconnecting) {
                            disconnect()
                        }
                    }
                }
            )
        }.getOrElse {
            showStatus(
                it.message ?: "Could not watch session"
            )
            null
        }
    }

    private fun advanceControllerState(id: String) {
        runCatching {
            var state = SessionCoordinator.snapshot()

            if (
                state.sessionId != null &&
                state.sessionId != id &&
                state.state != SessionState.CLOSED
            ) {
                return@runCatching
            }

            if (
                state.state == SessionState.IDLE ||
                state.state == SessionState.SETUP_REQUIRED ||
                state.state == SessionState.CLOSED
            ) {
                SessionCoordinator.prepareReady()
                state = SessionCoordinator.snapshot()
            }

            if (state.state == SessionState.READY) {
                SessionCoordinator.transition(
                    id,
                    SessionState.PAIR_PENDING
                )
                state = SessionCoordinator.snapshot()
            }

            if (state.state == SessionState.PAIR_PENDING) {
                SessionCoordinator.transition(
                    id,
                    SessionState.HOST_APPROVED
                )
                state = SessionCoordinator.snapshot()
            }

            if (state.state == SessionState.HOST_APPROVED) {
                SessionCoordinator.transition(
                    id,
                    SessionState.SCREEN_CONSENT
                )
                state = SessionCoordinator.snapshot()
            }

            if (state.state == SessionState.SCREEN_CONSENT) {
                SessionCoordinator.transition(
                    id,
                    SessionState.CONNECTING
                )
            }
        }
    }

    private fun ensureRtcStarted(id: String) {
        if (rtcSession != null) return

        showStatus("Establishing low-latency link…")

        var createdSession: ControllerWebRtcSession? = null
        rtcSession = runCatching {
            ControllerWebRtcSession(
            context = this,
            sessionId = id,
            listener = object : ControllerWebRtcSession.Listener {
                override fun onLive(geometry: RemoteGeometry) {
                    runOnUiThread {
                        remoteGeometry = geometry
                        if (remoteTrack != null) {
                            statusPanel.visibility = View.GONE
                        }
                    }
                }

                override fun onConnectivityChanged(
                    connected: Boolean
                ) {
                    runOnUiThread {
                        rtcConnected = connected
                        disconnectTimeout?.cancel()
                        disconnectTimeout = null

                        if (connected) {
                            if (
                                remoteTrack != null &&
                                remoteGeometry != null
                            ) {
                                statusPanel.visibility = View.GONE
                            }
                        } else {
                            showStatus("Reconnecting…")
                            disconnectTimeout = scope.launch {
                                delay(DISCONNECT_GRACE_MS)
                                if (!rtcConnected && !disconnecting) {
                                    disconnect()
                                }
                            }
                        }
                    }
                }

                override fun onRemoteVideoTrack(track: VideoTrack) {
                    runOnUiThread {
                        remoteTrack?.removeSink(renderer)
                        remoteTrack = track
                        track.addSink(renderer)

                        if (remoteGeometry != null) {
                            statusPanel.visibility = View.GONE
                        } else {
                            showStatus(
                                "Video connected • syncing controls…"
                            )
                        }
                    }
                }

                override fun onError(error: Throwable) {
                    runOnUiThread {
                        if (!disconnecting) {
                            disconnect()
                        }
                    }
                }
            }
            ).also {
                createdSession = it
                it.start()
            }
        }.getOrElse { error ->
            runCatching { createdSession?.close() }
            showStatus(
                error.message ?: "Could not start remote connection"
            )
            BackendSessionCloser.close(this, id)
            SessionCoordinator.close(id)
            null
        }
    }

    private fun updateControllerDeadline(
        id: String,
        deadlineAtEpochMs: Long?,
        backendState: String
    ) {
        if (
            backendState == "LIVE" ||
            backendState == "CLOSED"
        ) {
            sessionDeadlineJob?.cancel()
            sessionDeadlineJob = null
            return
        }

        val deadline = deadlineAtEpochMs ?: return
        sessionDeadlineJob?.cancel()
        sessionDeadlineJob = scope.launch {
            val remaining =
                (
                    deadline -
                        System.currentTimeMillis() +
                        CLIENT_DEADLINE_GRACE_MS
                ).coerceAtLeast(0L)
            delay(remaining)

            if (
                !disconnecting &&
                sessionId == id
            ) {
                disconnect()
            }
        }
    }

    private fun disconnect() {
        if (disconnecting) return
        disconnecting = true

        val id = sessionId
        if (id == null) {
            finish()
            return
        }

        showStatus("Ending session…")

        rtcSession?.close()
        rtcSession = null

        BackendSessionCloser.close(this, id)
        SessionCoordinator.close(id)
        finish()
    }

    private fun buildUi(): FrameLayout {
        fun dp(value: Int) = AarisUi.dp(this, value)

        val root = FrameLayout(this).apply {
            setBackgroundColor(AarisUi.REMOTE_CANVAS)
        }

        renderer = SurfaceViewRenderer(this).apply {
            init(
                WebRtcRuntime.eglBase(this@RemoteControlActivity)
                    .eglBaseContext,
                object : RendererCommon.RendererEvents {
                    override fun onFirstFrameRendered() = Unit

                    override fun onFrameResolutionChanged(
                        videoWidth: Int,
                        videoHeight: Int,
                        rotation: Int
                    ) {
                        val rotated = rotation % 180 != 0
                        renderedFrameWidth =
                            if (rotated) videoHeight else videoWidth
                        renderedFrameHeight =
                            if (rotated) videoWidth else videoHeight
                    }
                }
            )
            setScalingType(
                RendererCommon.ScalingType.SCALE_ASPECT_FIT
            )
            setEnableHardwareScaler(true)
            setMirror(false)
            setOnTouchListener { view, event ->
                val handled = handleRemoteTouch(event)
                if (
                    handled &&
                    event.actionMasked == MotionEvent.ACTION_UP
                ) {
                    view.performClick()
                }
                handled
            }
        }

        root.addView(
            renderer,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        statusPanel = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = AarisUi.panel(
                context = this@RemoteControlActivity,
                fill = AarisUi.REMOTE_PANEL,
                radiusDp = 18,
                strokeColor = AarisUi.REMOTE_BORDER
            )
            setPadding(dp(14), dp(10), dp(14), dp(10))
            elevation = dp(4).toFloat()
        }

        statusProgress = ProgressBar(this).apply {
            isIndeterminate = true
            AarisUi.tintProgress(this, AarisUi.REMOTE_ACCENT)
        }
        statusPanel.addView(
            statusProgress,
            LinearLayout.LayoutParams(
                dp(20),
                dp(20)
            ).apply {
                marginEnd = dp(10)
            }
        )

        status = TextView(this).apply {
            text = "Connecting…"
            setTextColor(Color.WHITE)
            textSize = 14f
            typeface = android.graphics.Typeface.create(
                "sans-serif-medium",
                android.graphics.Typeface.NORMAL
            )
            gravity = Gravity.CENTER_VERTICAL
        }

        statusPanel.addView(
            status,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            statusPanel,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            ).apply {
                topMargin = dp(16)
                marginStart = dp(16)
                marginEnd = dp(16)
            }
        )

        controlDock = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(6), dp(6), dp(6), dp(6))
            background = AarisUi.panel(
                context = this@RemoteControlActivity,
                fill = AarisUi.REMOTE_PANEL,
                radiusDp = 22,
                strokeColor = AarisUi.REMOTE_BORDER
            )
            elevation = dp(6).toFloat()
        }

        controlDock.addView(
            compactButton("Back") {
                rtcSession?.sendBack()
            }
        )
        controlDock.addView(
            compactButton("Home") {
                rtcSession?.sendHome()
            }
        )
        controlDock.addView(
            compactButton("Apps") {
                rtcSession?.sendRecents()
            }
        )
        controlDock.addView(
            compactButton("Type") {
                showTextDialog()
            }
        )
        controlDock.addView(
            compactButton("Hide") {
                setControlDockVisible(false)
            }
        )
        controlDock.addView(
            compactButton("End", danger = true) {
                disconnect()
            }
        )

        root.addView(
            controlDock,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            ).apply {
                bottomMargin = dp(18)
                marginStart = dp(12)
                marginEnd = dp(12)
            }
        )

        controlHandle = compactButton("Controls") {
            setControlDockVisible(true)
        }.apply {
            visibility = View.GONE
        }

        root.addView(
            controlHandle,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.END
            ).apply {
                bottomMargin = dp(18)
                marginEnd = dp(14)
            }
        )

        return root
    }

    private fun setControlDockVisible(visible: Boolean) {
        if (!::controlDock.isInitialized || !::controlHandle.isInitialized) {
            return
        }

        controlDock.visibility =
            if (visible) View.VISIBLE else View.GONE
        controlHandle.visibility =
            if (visible) View.GONE else View.VISIBLE
    }

    private fun showTextDialog() {
        val input = EditText(this).apply {
            hint = "Text to enter"
            inputType =
                InputType.TYPE_CLASS_TEXT or
                    InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 2
            maxLines = 5
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle("Type on remote phone")
            .setMessage(
                "Text is sent only to a focused non-sensitive field. Password, OTP, PIN, and verification fields stay local to the sharing phone."
            )
            .setView(input)
            .setPositiveButton("SEND", null)
            .setNegativeButton("CANCEL", null)
            .create()

        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                .setOnClickListener {
                    val text = input.text?.toString().orEmpty()
                    if (text.isBlank()) {
                        input.error = "Enter text"
                        return@setOnClickListener
                    }

                    if (rtcSession?.sendText(text) == true) {
                        dialog.dismiss()
                    } else {
                        input.error = "Remote field is not ready"
                    }
                }
        }

        dialog.show()
        input.requestFocus()
    }

    private fun compactButton(
        label: String,
        danger: Boolean = false,
        action: () -> Unit
    ): Button = Button(this).apply {
        text = label
        contentDescription =
            if (danger) "End remote session" else label
        AarisUi.remoteDockButton(this, danger)
        setOnClickListener {
            AarisUi.haptic(this)
            action()
        }
    }

    private fun handleRemoteTouch(
        event: MotionEvent
    ): Boolean {
        val session = rtcSession ?: return true
        val geometry = remoteGeometry ?: return true

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                resetTwoFingerState()
                suppressSingleUp = false
                downX = event.x
                downY = event.y
                downAtMs = SystemClock.elapsedRealtime()
                return true
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                suppressSingleUp = true

                if (event.pointerCount != 2) {
                    resetTwoFingerState(keepSuppression = true)
                    return true
                }

                val first = normalizedPoint(
                    event.getX(0),
                    event.getY(0),
                    geometry
                )
                val second = normalizedPoint(
                    event.getX(1),
                    event.getY(1),
                    geometry
                )

                if (first == null || second == null) {
                    resetTwoFingerState(keepSuppression = true)
                    return true
                }

                firstPointerId = event.getPointerId(0)
                secondPointerId = event.getPointerId(1)
                firstStartNx = first.first
                firstStartNy = first.second
                secondStartNx = second.first
                secondStartNy = second.second
                twoFingerStartedAtMs =
                    SystemClock.elapsedRealtime()
                twoFingerActive = true
                return true
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (!twoFingerActive) {
                    suppressSingleUp = true
                    return true
                }

                val firstEnd = normalizedPointer(
                    event,
                    firstPointerId,
                    geometry
                )
                val secondEnd = normalizedPointer(
                    event,
                    secondPointerId,
                    geometry
                )

                if (firstEnd != null && secondEnd != null) {
                    val duration = (
                        SystemClock.elapsedRealtime() -
                            twoFingerStartedAtMs
                    ).coerceIn(80L, 1_500L)

                    session.sendTwoFingerGesture(
                        firstFromNx = firstStartNx,
                        firstFromNy = firstStartNy,
                        firstToNx = firstEnd.first,
                        firstToNy = firstEnd.second,
                        secondFromNx = secondStartNx,
                        secondFromNy = secondStartNy,
                        secondToNx = secondEnd.first,
                        secondToNy = secondEnd.second,
                        durationMs = duration.toInt()
                    )
                }

                resetTwoFingerState(keepSuppression = true)
                return true
            }

            MotionEvent.ACTION_UP -> {
                if (suppressSingleUp) {
                    resetTwoFingerState()
                    suppressSingleUp = false
                    return true
                }

                val start = normalizedPoint(
                    downX,
                    downY,
                    geometry
                ) ?: return true

                val end = normalizedPoint(
                    event.x,
                    event.y,
                    geometry
                ) ?: return true

                val duration = (
                    SystemClock.elapsedRealtime() - downAtMs
                ).coerceIn(1L, 5_000L)

                val distance = hypot(
                    event.x - downX,
                    event.y - downY
                )

                if (distance <= touchSlop) {
                    if (duration >= 500L) {
                        session.sendLongPress(
                            end.first,
                            end.second,
                            duration.toInt()
                        )
                    } else {
                        session.sendTap(
                            end.first,
                            end.second
                        )
                    }
                } else {
                    session.sendSwipe(
                        start.first,
                        start.second,
                        end.first,
                        end.second,
                        duration.toInt().coerceIn(
                            80,
                            1500
                        )
                    )
                }
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                resetTwoFingerState()
                suppressSingleUp = false
                return true
            }
        }

        return true
    }

    private fun normalizedPointer(
        event: MotionEvent,
        pointerId: Int,
        geometry: RemoteGeometry
    ): Pair<Float, Float>? {
        if (pointerId == MotionEvent.INVALID_POINTER_ID) {
            return null
        }

        val index = event.findPointerIndex(pointerId)
        if (index < 0) return null

        return normalizedPoint(
            event.getX(index),
            event.getY(index),
            geometry
        )
    }

    private fun resetTwoFingerState(
        keepSuppression: Boolean = false
    ) {
        twoFingerActive = false
        firstPointerId = MotionEvent.INVALID_POINTER_ID
        secondPointerId = MotionEvent.INVALID_POINTER_ID
        firstStartNx = 0f
        firstStartNy = 0f
        secondStartNx = 0f
        secondStartNy = 0f
        twoFingerStartedAtMs = 0L

        if (!keepSuppression) {
            suppressSingleUp = false
        }
    }

    private fun normalizedPoint(
        x: Float,
        y: Float,
        geometry: RemoteGeometry
    ): Pair<Float, Float>? {
        val frameWidth =
            renderedFrameWidth.takeIf { it > 0 }
                ?: geometry.widthPx
        val frameHeight =
            renderedFrameHeight.takeIf { it > 0 }
                ?: geometry.heightPx

        if (
            !RemoteViewportMapper.frameMatchesRemote(
                remoteWidth = geometry.widthPx,
                remoteHeight = geometry.heightPx,
                frameWidth = frameWidth,
                frameHeight = frameHeight
            )
        ) {
            return null
        }

        val point = RemoteViewportMapper.normalize(
            touchX = x,
            touchY = y,
            viewWidth = renderer.width.toFloat(),
            viewHeight = renderer.height.toFloat(),
            remoteWidth = geometry.widthPx,
            remoteHeight = geometry.heightPx,
            frameWidth = frameWidth,
            frameHeight = frameHeight
        ) ?: return null

        return point.x to point.y
    }

    private fun showStatus(message: String) {
        statusPanel.visibility = View.VISIBLE
        status.text = message

        val value = message.lowercase()
        val busy = listOf(
            "waiting",
            "connecting",
            "establishing",
            "syncing",
            "reconnecting",
            "ending"
        ).any(value::contains)

        statusProgress.visibility =
            if (busy) View.VISIBLE else View.GONE
    }

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
        private const val CLIENT_DEADLINE_GRACE_MS = 2_000L
        private const val DISCONNECT_GRACE_MS = 25_000L
    }
}
