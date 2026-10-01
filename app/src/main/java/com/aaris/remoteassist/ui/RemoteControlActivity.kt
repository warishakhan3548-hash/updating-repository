package com.aaris.remoteassist.ui

import android.app.AlertDialog
import android.content.Intent
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
    private var lastCommandResultSequence = 0L

    private var downX = 0f
    private var downY = 0f
    private var downAtMs = 0L
    private val singleGesturePoints =
        ArrayList<Pair<Float, Float>>(MAX_GESTURE_PATH_POINTS)
    private var singleGestureGeneration = -1
    private var singleGestureInvalid = false
    private var singleGestureExceededSlop = false

    private var twoFingerActive = false
    private var suppressSingleUp = false
    private var twoFingerStartedAtMs = 0L
    private var twoFingerGeneration = -1
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

        val viewerReady = runCatching {
            WebRtcRuntime.initialize(this)
            setContentView(buildUi())
        }.isSuccess

        if (!viewerReady) {
            BackendSessionCloser.close(this, requestedSessionId)
            SessionCoordinator.close(requestedSessionId)
            setResult(
                RESULT_CANCELED,
                Intent().putExtra(
                    EXTRA_RESULT_MESSAGE,
                    "Could not open the remote viewer. Try connecting again."
                )
            )
            finish()
            return
        }

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

        rtcSession?.close(notifyRemote = false)
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
                                // SCREEN_READY is authoritative backend proof
                                // that this authenticated controller already
                                // redeemed the code and the host granted screen
                                // consent. Rebuild volatile local state first so
                                // an Activity/process recreation cannot falsely
                                // turn a valid session into "interrupted".
                                advanceControllerState(id)

                                val local =
                                    SessionCoordinator.snapshot()
                                val resumable =
                                    local.sessionId == id &&
                                        (
                                            local.state ==
                                                SessionState.CONNECTING ||
                                                local.state ==
                                                    SessionState.LIVE
                                        )

                                if (!resumable) {
                                    finishController(
                                        "Session was interrupted. Connect again with a new code."
                                    )
                                    return@runOnUiThread
                                }

                                ensureRtcStarted(id)
                            }

                            "LIVE" -> {
                                if (rtcSession == null) {
                                    advanceControllerState(id)
                                    val local =
                                        SessionCoordinator.snapshot()
                                    val resumable =
                                        local.sessionId == id &&
                                            (
                                                local.state ==
                                                    SessionState.CONNECTING ||
                                                local.state ==
                                                    SessionState.LIVE
                                            )

                                    if (!resumable) {
                                        finishController(
                                            "Session was interrupted. Connect again with a new code."
                                        )
                                        return@runOnUiThread
                                    }

                                    ensureRtcStarted(id)
                                    return@runOnUiThread
                                }

                                runCatching {
                                    val local =
                                        SessionCoordinator.snapshot()
                                    if (
                                        local.sessionId == id &&
                                        local.state ==
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
                                finishController(
                                    message = "Session ended.",
                                    closeBackend = false
                                )
                            }
                        }
                    }
                },
                onError = {
                    runOnUiThread {
                        if (!disconnecting) {
                            finishController(
                                "Connection lost. Check internet and try again."
                            )
                        }
                    }
                }
            )
        }.getOrElse {
            finishController(
                "Could not start the connection. Check internet and try again."
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
                        runCatching {
                            val local =
                                SessionCoordinator.snapshot()
                            if (
                                local.sessionId == id &&
                                local.state ==
                                    SessionState.CONNECTING
                            ) {
                                SessionCoordinator.transition(
                                    id,
                                    SessionState.LIVE
                                )
                            }
                        }

                        if (
                            singleGestureGeneration >= 0 &&
                            singleGestureGeneration != geometry.generation
                        ) {
                            singleGestureInvalid = true
                        }
                        if (
                            twoFingerActive &&
                            twoFingerGeneration != geometry.generation
                        ) {
                            resetTwoFingerState(
                                keepSuppression = true
                            )
                        }

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
                                    finishController(
                                        "Connection lost. Check internet and try again."
                                    )
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

                override fun onCommandResult(
                    sequence: Long,
                    applied: Boolean
                ) {
                    runOnUiThread {
                        if (disconnecting || !rtcConnected) {
                            return@runOnUiThread
                        }
                        if (sequence <= lastCommandResultSequence) {
                            return@runOnUiThread
                        }
                        lastCommandResultSequence = sequence

                        if (applied) {
                            if (
                                status.text.toString() ==
                                COMMAND_NOT_APPLIED_MESSAGE
                            ) {
                                statusPanel.visibility = View.GONE
                            }
                        } else {
                            showStatus(
                                COMMAND_NOT_APPLIED_MESSAGE
                            )
                        }
                    }
                }

                override fun onError(error: Throwable) {
                    runOnUiThread {
                        if (!disconnecting) {
                            finishController(
                                "Connection failed. Check internet and try again."
                            )
                        }
                    }
                }
            }
            ).also {
                createdSession = it
                it.start()
            }
        }.getOrElse {
            runCatching { createdSession?.close() }
            finishController(
                "Could not start the remote connection. Try again."
            )
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
                finishController(
                    "Connection setup expired. Try again."
                )
            }
        }
    }

    private fun disconnect() {
        finishController("Session ended.")
    }

    private fun finishController(
        message: String,
        closeBackend: Boolean = true
    ) {
        if (disconnecting) return
        disconnecting = true

        disconnectTimeout?.cancel()
        disconnectTimeout = null
        sessionDeadlineJob?.cancel()
        sessionDeadlineJob = null

        rtcSession?.close()
        rtcSession = null

        val id = sessionId
        if (id != null) {
            if (closeBackend) {
                BackendSessionCloser.close(this, id)
            }
            SessionCoordinator.close(id)
        }

        setResult(
            RESULT_OK,
            Intent().putExtra(
                EXTRA_RESULT_MESSAGE,
                message
            )
        )

        showStatus(message)
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
                0,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1f
            )
        )

        root.addView(
            statusPanel,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
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

        fun addDockControl(
            label: String,
            danger: Boolean = false,
            action: () -> Unit
        ) {
            controlDock.addView(
                compactButton(
                    label = label,
                    danger = danger,
                    action = action
                ),
                LinearLayout.LayoutParams(
                    0,
                    dp(44),
                    1f
                )
            )
        }

        addDockControl("Back") {
            if (rtcSession?.sendBack() != true) {
                showStatus(COMMAND_NOT_APPLIED_MESSAGE)
            }
        }
        addDockControl("Home") {
            if (rtcSession?.sendHome() != true) {
                showStatus(COMMAND_NOT_APPLIED_MESSAGE)
            }
        }
        addDockControl("Apps") {
            if (rtcSession?.sendRecents() != true) {
                showStatus(COMMAND_NOT_APPLIED_MESSAGE)
            }
        }
        addDockControl("Type") {
            showTextDialog()
        }
        addDockControl("Hide") {
            setControlDockVisible(false)
        }
        addDockControl("End", danger = true) {
            disconnect()
        }

        root.addView(
            controlDock,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
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

        @Suppress("DEPRECATION")
        root.setOnApplyWindowInsetsListener { _, insets ->
            (statusPanel.layoutParams as? FrameLayout.LayoutParams)
                ?.let { params ->
                    params.topMargin =
                        dp(16) + insets.systemWindowInsetTop
                    params.marginStart =
                        dp(16) + insets.systemWindowInsetLeft
                    params.marginEnd =
                        dp(16) + insets.systemWindowInsetRight
                    statusPanel.layoutParams = params
                }

            (controlDock.layoutParams as? FrameLayout.LayoutParams)
                ?.let { params ->
                    params.bottomMargin =
                        dp(18) + insets.systemWindowInsetBottom
                    params.marginStart =
                        dp(12) + insets.systemWindowInsetLeft
                    params.marginEnd =
                        dp(12) + insets.systemWindowInsetRight
                    controlDock.layoutParams = params
                }

            (controlHandle.layoutParams as? FrameLayout.LayoutParams)
                ?.let { params ->
                    params.bottomMargin =
                        dp(18) + insets.systemWindowInsetBottom
                    params.marginEnd =
                        dp(14) + insets.systemWindowInsetRight
                    controlHandle.layoutParams = params
                }

            insets
        }
        root.requestApplyInsets()

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
                resetSingleGestureState()
                suppressSingleUp = false
                downX = event.x
                downY = event.y
                downAtMs = SystemClock.elapsedRealtime()
                singleGestureGeneration = geometry.generation
                singleGestureExceededSlop = false
                singleGestureInvalid =
                    !appendSingleGesturePoint(
                        event.x,
                        event.y,
                        geometry
                    )
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                if (
                    suppressSingleUp ||
                    twoFingerActive ||
                    singleGestureInvalid
                ) {
                    return true
                }

                if (
                    geometry.generation != singleGestureGeneration
                ) {
                    singleGestureInvalid = true
                    return true
                }

                for (index in 0 until event.historySize) {
                    val historicalX = event.getHistoricalX(index)
                    val historicalY = event.getHistoricalY(index)
                    if (
                        !singleGestureExceededSlop &&
                        hypot(
                            historicalX - downX,
                            historicalY - downY
                        ) > touchSlop
                    ) {
                        singleGestureExceededSlop = true
                    }
                    if (
                        !appendSingleGesturePoint(
                            historicalX,
                            historicalY,
                            geometry,
                            clampToContent = true
                        )
                    ) {
                        singleGestureInvalid = true
                        return true
                    }
                }

                if (
                    !singleGestureExceededSlop &&
                    hypot(
                        event.x - downX,
                        event.y - downY
                    ) > touchSlop
                ) {
                    singleGestureExceededSlop = true
                }

                if (
                    !appendSingleGesturePoint(
                        event.x,
                        event.y,
                        geometry,
                        clampToContent = true
                    )
                ) {
                    singleGestureInvalid = true
                }
                return true
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                suppressSingleUp = true
                singleGestureInvalid = true
                singleGesturePoints.clear()

                if (event.pointerCount != 2) {
                    resetTwoFingerState(
                        keepSuppression = true
                    )
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
                    resetTwoFingerState(
                        keepSuppression = true
                    )
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
                twoFingerGeneration = geometry.generation
                twoFingerActive = true
                return true
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (!twoFingerActive) {
                    suppressSingleUp = true
                    return true
                }

                if (
                    geometry.generation != twoFingerGeneration
                ) {
                    resetTwoFingerState(
                        keepSuppression = true
                    )
                    return true
                }

                val firstEnd = normalizedPointer(
                    event,
                    firstPointerId,
                    geometry,
                    clampToContent = true
                )
                val secondEnd = normalizedPointer(
                    event,
                    secondPointerId,
                    geometry,
                    clampToContent = true
                )

                if (firstEnd != null && secondEnd != null) {
                    val duration = (
                        SystemClock.elapsedRealtime() -
                            twoFingerStartedAtMs
                    ).coerceIn(80L, 1_500L)

                    val queued = session.sendTwoFingerGesture(
                        firstFromNx = firstStartNx,
                        firstFromNy = firstStartNy,
                        firstToNx = firstEnd.first,
                        firstToNy = firstEnd.second,
                        secondFromNx = secondStartNx,
                        secondFromNy = secondStartNy,
                        secondToNx = secondEnd.first,
                        secondToNy = secondEnd.second,
                        durationMs = duration.toInt(),
                        expectedGeneration =
                            twoFingerGeneration
                    )
                    if (!queued) {
                        showStatus(COMMAND_NOT_APPLIED_MESSAGE)
                    }
                }

                resetTwoFingerState(
                    keepSuppression = true
                )
                return true
            }

            MotionEvent.ACTION_UP -> {
                if (suppressSingleUp) {
                    resetTwoFingerState()
                    resetSingleGestureState()
                    suppressSingleUp = false
                    return true
                }

                if (
                    singleGestureInvalid ||
                    singleGestureGeneration < 0 ||
                    geometry.generation != singleGestureGeneration
                ) {
                    resetSingleGestureState()
                    return true
                }

                val end = normalizedPoint(
                    event.x,
                    event.y,
                    geometry,
                    clampToContent = true
                )
                if (end == null) {
                    resetSingleGestureState()
                    return true
                }

                if (
                    !appendSingleGesturePoint(
                        event.x,
                        event.y,
                        geometry,
                        force = true,
                        clampToContent = true
                    )
                ) {
                    resetSingleGestureState()
                    return true
                }

                val duration = (
                    SystemClock.elapsedRealtime() - downAtMs
                ).coerceIn(1L, 5_000L)

                val distance = hypot(
                    event.x - downX,
                    event.y - downY
                )

                if (distance > touchSlop) {
                    singleGestureExceededSlop = true
                }

                val generation = singleGestureGeneration
                if (!singleGestureExceededSlop) {
                    if (duration >= 500L) {
                        if (
                            !session.sendLongPress(
                                end.first,
                                end.second,
                                duration.toInt(),
                                expectedGeneration = generation
                            )
                        ) {
                            showStatus(COMMAND_NOT_APPLIED_MESSAGE)
                        }
                    } else {
                        if (
                            !session.sendTap(
                                end.first,
                                end.second,
                                expectedGeneration = generation
                            )
                        ) {
                            showStatus(COMMAND_NOT_APPLIED_MESSAGE)
                        }
                    }
                } else {
                    val points = singleGesturePoints.toList()
                    if (points.size >= 2) {
                        if (
                            !session.sendGesturePath(
                                points = points,
                                durationMs = duration.toInt()
                                    .coerceIn(80, 1_500),
                                expectedGeneration = generation
                            )
                        ) {
                            showStatus(COMMAND_NOT_APPLIED_MESSAGE)
                        }
                    }
                }

                resetSingleGestureState()
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                resetTwoFingerState()
                resetSingleGestureState()
                suppressSingleUp = false
                return true
            }
        }

        return true
    }

    private fun appendSingleGesturePoint(
        x: Float,
        y: Float,
        geometry: RemoteGeometry,
        force: Boolean = false,
        clampToContent: Boolean = false
    ): Boolean {
        if (
            geometry.generation != singleGestureGeneration
        ) {
            return false
        }

        val point = normalizedPoint(
            x,
            y,
            geometry,
            clampToContent = clampToContent
        ) ?: return false

        val candidate = point.first to point.second
        val last = singleGesturePoints.lastOrNull()
        if (last != null && !force) {
            val delta = hypot(
                candidate.first - last.first,
                candidate.second - last.second
            )
            if (delta < MIN_GESTURE_SAMPLE_DELTA) {
                if (singleGesturePoints.size > 1) {
                    singleGesturePoints[
                        singleGesturePoints.lastIndex
                    ] = candidate
                }
                return true
            }
        }

        if (
            singleGesturePoints.size >=
            MAX_GESTURE_PATH_POINTS
        ) {
            compactSingleGesturePath()
        }

        val tail = singleGesturePoints.lastOrNull()
        if (tail != candidate) {
            singleGesturePoints += candidate
        }
        return true
    }

    private fun compactSingleGesturePath() {
        if (singleGesturePoints.size < 3) return

        val compacted =
            ArrayList<Pair<Float, Float>>(
                (singleGesturePoints.size / 2) + 2
            )
        compacted += singleGesturePoints.first()

        var index = 2
        while (index < singleGesturePoints.lastIndex) {
            compacted += singleGesturePoints[index]
            index += 2
        }

        val last = singleGesturePoints.last()
        if (compacted.last() != last) {
            compacted += last
        }

        singleGesturePoints.clear()
        singleGesturePoints.addAll(compacted)
    }

    private fun resetSingleGestureState() {
        singleGesturePoints.clear()
        singleGestureGeneration = -1
        singleGestureInvalid = false
        singleGestureExceededSlop = false
    }

    private fun normalizedPointer(
        event: MotionEvent,
        pointerId: Int,
        geometry: RemoteGeometry,
        clampToContent: Boolean = false
    ): Pair<Float, Float>? {
        if (pointerId == MotionEvent.INVALID_POINTER_ID) {
            return null
        }

        val index = event.findPointerIndex(pointerId)
        if (index < 0) return null

        return normalizedPoint(
            event.getX(index),
            event.getY(index),
            geometry,
            clampToContent = clampToContent
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
        twoFingerGeneration = -1

        if (!keepSuppression) {
            suppressSingleUp = false
        }
    }

    private fun normalizedPoint(
        x: Float,
        y: Float,
        geometry: RemoteGeometry,
        clampToContent: Boolean = false
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
            frameHeight = frameHeight,
            clampToContent = clampToContent
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
        private const val COMMAND_NOT_APPLIED_MESSAGE =
            "Action wasn’t applied on the remote phone."
        const val EXTRA_RESULT_MESSAGE = "result_message"
        private const val CLIENT_DEADLINE_GRACE_MS = 2_000L
        private const val DISCONNECT_GRACE_MS = 25_000L
        private const val MAX_GESTURE_PATH_POINTS = 96
        private const val MIN_GESTURE_SAMPLE_DELTA = 0.0015f
    }
}
