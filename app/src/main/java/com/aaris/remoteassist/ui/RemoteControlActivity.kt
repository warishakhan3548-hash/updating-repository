package com.aaris.remoteassist.ui

import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
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
    private lateinit var status: TextView

    private var observer: Closeable? = null
    private var rtcSession: ControllerWebRtcSession? = null
    private var remoteTrack: VideoTrack? = null
    private var sessionId: String? = null
    private var remoteGeometry: RemoteGeometry? = null
    private var disconnecting = false
    private var rtcConnected = false
    private var disconnectTimeout: Job? = null

    private var downX = 0f
    private var downY = 0f
    private var downAtMs = 0L

    private val touchSlop by lazy {
        ViewConfiguration.get(this).scaledTouchSlop.toFloat()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )

        sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
        if (sessionId == null) {
            finish()
            return
        }

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
        observe(sessionId!!)
    }

    override fun onDestroy() {
        observer?.close()
        observer = null

        remoteTrack?.removeSink(renderer)
        remoteTrack = null

        disconnectTimeout?.cancel()
        disconnectTimeout = null

        rtcSession?.close()
        rtcSession = null

        if (::renderer.isInitialized) {
            renderer.release()
        }

        scope.cancel()
        super.onDestroy()
    }

    private fun observe(id: String) {
        observer = runCatching {
            gateway.observeSession(
                id,
                listener = { backend ->
                    runOnUiThread {
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
                                advanceControllerState(id)
                                ensureRtcStarted(id)
                            }

                            "LIVE" -> {
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
                                    status.visibility = View.GONE
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

        rtcSession = ControllerWebRtcSession(
            context = this,
            sessionId = id,
            listener = object : ControllerWebRtcSession.Listener {
                override fun onLive(geometry: RemoteGeometry) {
                    runOnUiThread {
                        remoteGeometry = geometry
                        if (remoteTrack != null) {
                            status.visibility = View.GONE
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
                                status.visibility = View.GONE
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
                            status.visibility = View.GONE
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
        ).also { it.start() }
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

        scope.launch {
            runCatching { gateway.close(id) }
            SessionCoordinator.close(id)
            finish()
        }
    }

    private fun buildUi(): FrameLayout {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        renderer = SurfaceViewRenderer(this).apply {
            init(
                WebRtcRuntime.eglBase(this@RemoteControlActivity)
                    .eglBaseContext,
                null
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

        status = TextView(this).apply {
            text = "Connecting…"
            setTextColor(Color.WHITE)
            setBackgroundColor(
                Color.argb(140, 0, 0, 0)
            )
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(24, 16, 24, 16)
        }

        root.addView(
            status,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )

        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(8, 6, 8, 6)
            setBackgroundColor(
                Color.argb(190, 0, 0, 0)
            )
        }

        controls.addView(
            compactButton("Back") {
                rtcSession?.sendBack()
            }
        )
        controls.addView(
            compactButton("Home") {
                rtcSession?.sendHome()
            }
        )
        controls.addView(
            compactButton("Apps") {
                rtcSession?.sendRecents()
            }
        )
        controls.addView(
            compactButton("Type") {
                showTextDialog()
            }
        )
        controls.addView(
            compactButton("End") {
                disconnect()
            }
        )

        root.addView(
            controls,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            )
        )

        return root
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
                "Text is sent only to the focused non-password field."
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
        action: () -> Unit
    ): Button = Button(this).apply {
        text = label
        isAllCaps = false
        textSize = 12f
        minWidth = 0
        minimumWidth = 0
        minHeight = 0
        minimumHeight = 0
        setPadding(12, 8, 12, 8)
        setOnClickListener { action() }
    }

    private fun handleRemoteTouch(
        event: MotionEvent
    ): Boolean {
        val session = rtcSession ?: return true
        val geometry = remoteGeometry ?: return true

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                downAtMs = SystemClock.elapsedRealtime()
                return true
            }

            MotionEvent.ACTION_UP -> {
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

            MotionEvent.ACTION_CANCEL -> return true
        }

        return true
    }

    private fun normalizedPoint(
        x: Float,
        y: Float,
        geometry: RemoteGeometry
    ): Pair<Float, Float>? {
        val point = RemoteViewportMapper.normalize(
            touchX = x,
            touchY = y,
            viewWidth = renderer.width.toFloat(),
            viewHeight = renderer.height.toFloat(),
            remoteWidth = geometry.widthPx,
            remoteHeight = geometry.heightPx
        ) ?: return null

        return point.x to point.y
    }

    private fun showStatus(message: String) {
        status.visibility = View.VISIBLE
        status.text = message
    }

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
        private const val DISCONNECT_GRACE_MS = 15_000L
    }
}
