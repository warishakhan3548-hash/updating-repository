package com.aaris.remoteassist.ui

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
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
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

class RemoteControlActivity : Activity() {
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Main
    )
    private val gateway by lazy {
        FirebasePairingGateway(this)
    }

    private lateinit var renderer:
        SurfaceViewRenderer
    private lateinit var status:
        TextView

    private var observer: Closeable? = null
    private var rtcSession:
        ControllerWebRtcSession? = null
    private var remoteTrack:
        VideoTrack? = null
    private var sessionId:
        String? = null
    private var remoteGeometry:
        RemoteGeometry? = null

    private var downX = 0f
    private var downY = 0f
    private var downAtMs = 0L

    private val touchSlop by lazy {
        ViewConfiguration
            .get(this)
            .scaledTouchSlop
            .toFloat()
    }

    override fun onCreate(
        savedInstanceState: Bundle?
    ) {
        super.onCreate(
            savedInstanceState
        )

        window.addFlags(
            WindowManager.LayoutParams
                .FLAG_KEEP_SCREEN_ON
        )

        sessionId =
            intent.getStringExtra(
                EXTRA_SESSION_ID
            )

        if (sessionId == null) {
            finish()
            return
        }

        WebRtcRuntime.initialize(this)
        setContentView(buildUi())
        observe(sessionId!!)
    }

    override fun onDestroy() {
        observer?.close()
        observer = null

        remoteTrack?.removeSink(
            renderer
        )
        remoteTrack = null

        rtcSession?.close()
        rtcSession = null

        if (::renderer.isInitialized) {
            renderer.release()
        }

        scope.cancel()
        super.onDestroy()
    }

    private fun observe(
        id: String
    ) {
        observer = runCatching {
            gateway.observeSession(
                id,
                listener = { backend ->
                    runOnUiThread {
                        when (
                            backend.state
                        ) {
                            "PAIR_PENDING" ->
                                showStatus(
                                    "Waiting for your friend to tap START…"
                                )

                            "HOST_APPROVED" ->
                                showStatus(
                                    "Waiting for screen-share permission…"
                                )

                            "SCREEN_READY" -> {
                                advanceControllerState(
                                    id
                                )
                                ensureRtcStarted(
                                    id
                                )
                            }

                            "LIVE" -> {
                                advanceControllerState(
                                    id
                                )
                                ensureRtcStarted(
                                    id
                                )

                                runCatching {
                                    if (
                                        SessionCoordinator
                                            .snapshot()
                                            .state ==
                                        SessionState.CONNECTING
                                    ) {
                                        SessionCoordinator
                                            .transition(
                                                id,
                                                SessionState.LIVE
                                            )
                                    }
                                }

                                updateConnectedStatus()
                            }

                            "CLOSED" -> {
                                SessionCoordinator
                                    .close(id)
                                closeRtcOnly()
                                showStatus(
                                    "Session ended"
                                )
                            }
                        }
                    }
                },
                onError = {
                    runOnUiThread {
                        showStatus(
                            "Connection watcher stopped"
                        )
                    }
                }
            )
        }.getOrElse {
            showStatus(
                it.message
                    ?: "Could not watch session"
            )
            null
        }
    }

    private fun advanceControllerState(
        id: String
    ) {
        runCatching {
            var state =
                SessionCoordinator
                    .snapshot()

            if (
                state.state ==
                SessionState.PAIR_PENDING
            ) {
                SessionCoordinator
                    .transition(
                        id,
                        SessionState.HOST_APPROVED
                    )

                state =
                    SessionCoordinator
                        .snapshot()
            }

            if (
                state.state ==
                SessionState.HOST_APPROVED
            ) {
                SessionCoordinator
                    .transition(
                        id,
                        SessionState.SCREEN_CONSENT
                    )

                state =
                    SessionCoordinator
                        .snapshot()
            }

            if (
                state.state ==
                SessionState.SCREEN_CONSENT
            ) {
                SessionCoordinator
                    .transition(
                        id,
                        SessionState.CONNECTING
                    )
            }
        }
    }

    private fun ensureRtcStarted(
        id: String
    ) {
        if (rtcSession != null) {
            return
        }

        showStatus(
            "Establishing low-latency link…"
        )

        rtcSession =
            ControllerWebRtcSession(
                context = this,
                sessionId = id,
                listener =
                    object :
                        ControllerWebRtcSession.Listener {
                        override fun onLive(
                            geometry:
                                RemoteGeometry
                        ) {
                            runOnUiThread {
                                remoteGeometry =
                                    geometry
                                updateConnectedStatus()
                            }
                        }

                        override fun onConnectivityChanged(
                            connected: Boolean
                        ) {
                            runOnUiThread {
                                if (connected) {
                                    updateConnectedStatus()
                                } else {
                                    showStatus(
                                        "Reconnecting…"
                                    )
                                }
                            }
                        }

                        override fun onRemoteVideoTrack(
                            track:
                                VideoTrack
                        ) {
                            runOnUiThread {
                                remoteTrack
                                    ?.removeSink(
                                        renderer
                                    )

                                remoteTrack =
                                    track

                                track.addSink(
                                    renderer
                                )

                                updateConnectedStatus()
                            }
                        }

                        override fun onError(
                            error: Throwable
                        ) {
                            runOnUiThread {
                                showStatus(
                                    "Connection problem"
                                )
                            }
                        }
                    }
            ).also {
                it.start()
            }
    }

    private fun updateConnectedStatus() {
        if (
            remoteTrack != null &&
            remoteGeometry != null
        ) {
            status.visibility =
                View.GONE
        } else {
            showStatus(
                "Connected • syncing screen…"
            )
        }
    }

    private fun disconnect() {
        val id =
            sessionId ?: return

        closeRtcOnly()

        scope.launch {
            runCatching {
                gateway.close(id)
            }

            SessionCoordinator
                .close(id)

            finish()
        }
    }

    private fun closeRtcOnly() {
        remoteTrack?.removeSink(
            renderer
        )
        remoteTrack = null
        remoteGeometry = null

        rtcSession?.close()
        rtcSession = null
    }

    private fun buildUi():
        FrameLayout {
        val root =
            FrameLayout(this).apply {
                setBackgroundColor(
                    Color.BLACK
                )
            }

        renderer =
            SurfaceViewRenderer(
                this
            ).apply {
                init(
                    WebRtcRuntime
                        .eglBase(
                            this@RemoteControlActivity
                        )
                        .eglBaseContext,
                    null
                )

                setScalingType(
                    RendererCommon
                        .ScalingType
                        .SCALE_ASPECT_FIT
                )
                setEnableHardwareScaler(
                    true
                )
                setMirror(false)

                setOnTouchListener {
                        _,
                        event ->
                    handleRemoteTouch(
                        event
                    )
                }
            }

        root.addView(
            renderer,
            FrameLayout.LayoutParams(
                FrameLayout
                    .LayoutParams
                    .MATCH_PARENT,
                FrameLayout
                    .LayoutParams
                    .MATCH_PARENT
            )
        )

        status =
            TextView(this).apply {
                text = "Connecting…"
                setTextColor(
                    Color.WHITE
                )
                setBackgroundColor(
                    Color.argb(
                        140,
                        0,
                        0,
                        0
                    )
                )
                textSize = 16f
                gravity = Gravity.CENTER
                setPadding(
                    24,
                    16,
                    24,
                    16
                )
            }

        root.addView(
            status,
            FrameLayout.LayoutParams(
                FrameLayout
                    .LayoutParams
                    .WRAP_CONTENT,
                FrameLayout
                    .LayoutParams
                    .WRAP_CONTENT,
                Gravity.CENTER
            )
        )

        val controls =
            LinearLayout(this).apply {
                orientation =
                    LinearLayout.HORIZONTAL
                gravity =
                    Gravity.CENTER
                setPadding(
                    8,
                    6,
                    8,
                    6
                )
                setBackgroundColor(
                    Color.argb(
                        190,
                        0,
                        0,
                        0
                    )
                )
            }

        controls.addView(
            compactButton(
                "Back"
            ) {
                rtcSession
                    ?.sendBack()
            }
        )

        controls.addView(
            compactButton(
                "Home"
            ) {
                rtcSession
                    ?.sendHome()
            }
        )

        controls.addView(
            compactButton(
                "Disconnect"
            ) {
                disconnect()
            }
        )

        root.addView(
            controls,
            FrameLayout.LayoutParams(
                FrameLayout
                    .LayoutParams
                    .WRAP_CONTENT,
                FrameLayout
                    .LayoutParams
                    .WRAP_CONTENT,
                Gravity.BOTTOM or
                    Gravity
                        .CENTER_HORIZONTAL
            )
        )

        return root
    }

    private fun compactButton(
        label: String,
        action: () -> Unit
    ): Button =
        Button(this).apply {
            text = label
            isAllCaps = false
            setOnClickListener {
                action()
            }
        }

    private fun handleRemoteTouch(
        event: MotionEvent
    ): Boolean {
        val session =
            rtcSession ?: return true
        val geometry =
            remoteGeometry ?: return true

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                downAtMs =
                    SystemClock
                        .elapsedRealtime()
                return true
            }

            MotionEvent.ACTION_UP -> {
                val start =
                    normalizedPoint(
                        downX,
                        downY,
                        geometry
                    ) ?: return true

                val end =
                    normalizedPoint(
                        event.x,
                        event.y,
                        geometry
                    ) ?: return true

                val duration =
                    (
                        SystemClock
                            .elapsedRealtime() -
                            downAtMs
                        ).coerceIn(
                            1L,
                            5_000L
                        )

                val distance =
                    hypot(
                        event.x - downX,
                        event.y - downY
                    )

                if (
                    distance <=
                    touchSlop
                ) {
                    if (
                        duration >=
                        500L
                    ) {
                        session
                            .sendLongPress(
                                end.first,
                                end.second,
                                duration
                                    .toInt()
                            )
                    } else {
                        session
                            .sendTap(
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
                        duration
                            .toInt()
                            .coerceIn(
                                80,
                                1500
                            )
                    )
                }

                return true
            }

            MotionEvent.ACTION_CANCEL ->
                return true
        }

        return true
    }

    private fun normalizedPoint(
        x: Float,
        y: Float,
        geometry: RemoteGeometry
    ): Pair<Float, Float>? {
        val viewWidth =
            renderer.width.toFloat()
        val viewHeight =
            renderer.height.toFloat()

        if (
            viewWidth <= 0f ||
            viewHeight <= 0f
        ) {
            return null
        }

        val remoteAspect =
            geometry.widthPx
                .toFloat() /
                geometry.heightPx
                    .toFloat()

        val viewAspect =
            viewWidth /
                viewHeight

        val left: Float
        val top: Float
        val contentWidth: Float
        val contentHeight: Float

        if (
            viewAspect >
            remoteAspect
        ) {
            contentHeight =
                viewHeight
            contentWidth =
                viewHeight *
                    remoteAspect
            left =
                (
                    viewWidth -
                        contentWidth
                    ) / 2f
            top = 0f
        } else {
            contentWidth =
                viewWidth
            contentHeight =
                viewWidth /
                    remoteAspect
            left = 0f
            top =
                (
                    viewHeight -
                        contentHeight
                    ) / 2f
        }

        if (
            x < left ||
            x > left + contentWidth ||
            y < top ||
            y > top + contentHeight
        ) {
            return null
        }

        val nx =
            (
                (x - left) /
                    contentWidth
                ).coerceIn(
                    0f,
                    1f
                )

        val ny =
            (
                (y - top) /
                    contentHeight
                ).coerceIn(
                    0f,
                    1f
                )

        return nx to ny
    }

    private fun showStatus(
        message: String
    ) {
        status.visibility =
            View.VISIBLE
        status.text = message
    }

    companion object {
        const val EXTRA_SESSION_ID =
            "session_id"
    }
}
