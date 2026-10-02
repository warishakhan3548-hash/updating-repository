package com.aaris.remoteassist.ui

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.aaris.remoteassist.webrtc.ControllerConnectionRuntime
import com.aaris.remoteassist.webrtc.ControllerWebRtcSession
import com.aaris.remoteassist.webrtc.RemoteGeometry
import com.aaris.remoteassist.webrtc.WebRtcRuntime
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

/**
 * Full-screen controller UI that lives inside MainActivity.
 *
 * The foreground ControllerConnectionService owns WebRTC. This view only
 * presents the already-established session, avoiding the fragile Activity
 * handoff that repeatedly crashed/finished on physical devices.
 */
class InlineRemoteControllerView(
    private val activity: Activity,
    private val sessionId: String,
    private val onEnd: () -> Unit
) {
    private val root = FrameLayout(activity)
    private val status = TextView(activity)
    private val dock = LinearLayout(activity)
    private val rendererContainer = FrameLayout(activity)

    private var renderer: SurfaceViewRenderer? = null
    private var rendererInitialized = false
    private var remoteTrack: VideoTrack? = null
    private var sinkTrack: VideoTrack? = null
    private var geometry: RemoteGeometry? = null
    private var frameWidth = 0
    private var frameHeight = 0

    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L

    private var attached = false

    private val listener =
        object : ControllerWebRtcSession.Listener {
            override fun onLive(geometry: RemoteGeometry) {
                activity.runOnUiThread {
                    this@InlineRemoteControllerView.geometry =
                        geometry
                    status.text =
                        if (remoteTrack == null) {
                            "Connected • waiting for screen video…"
                        } else {
                            "Video connected • preparing display…"
                        }
                }
            }

            override fun onConnectivityChanged(
                connected: Boolean
            ) {
                activity.runOnUiThread {
                    if (!connected) {
                        status.visibility = View.VISIBLE
                        status.text =
                            "Connection interrupted • reconnecting…"
                    }
                }
            }

            override fun onRemoteVideoTrack(track: VideoTrack) {
                activity.runOnUiThread {
                    if (remoteTrack !== track) {
                        sinkTrack?.let { old ->
                            renderer?.let(old::removeSink)
                        }
                        sinkTrack = null
                        remoteTrack = track
                        track.setEnabled(true)
                    }

                    status.visibility = View.VISIBLE
                    status.text =
                        "Video connected • opening remote screen…"
                    scheduleRendererAttach()
                }
            }

            override fun onCommandResult(
                sequence: Long,
                applied: Boolean
            ) {
                if (!applied) {
                    activity.runOnUiThread {
                        status.visibility = View.VISIBLE
                        status.text =
                            "Control command was not applied on the sharing phone."
                    }
                }
            }

            override fun onDiagnostic(message: String) = Unit

            override fun onRecoverableError(
                error: Throwable
            ) {
                activity.runOnUiThread {
                    status.visibility = View.VISIBLE
                    status.text =
                        "Recovering secure connection…"
                }
            }

            override fun onTerminalError(
                error: Throwable
            ) {
                activity.runOnUiThread {
                    status.visibility = View.VISIBLE
                    status.text =
                        "Session connection ended."
                }
            }
        }

    fun show() {
        if (attached) return
        attached = true

        buildUi()

        activity.addContentView(
            root,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        ControllerConnectionRuntime.attach(
            sessionId,
            listener
        )

        root.post {
            ControllerConnectionRuntime.replayUiState(
                sessionId
            )
            scheduleRendererAttach()
        }
    }

    fun hide() {
        if (!attached) return
        attached = false

        ControllerConnectionRuntime.detach(listener)

        sinkTrack?.let { track ->
            renderer?.let(track::removeSink)
        }
        sinkTrack = null
        remoteTrack = null

        renderer?.let { view ->
            if (rendererInitialized) {
                runCatching { view.release() }
            }
        }
        renderer = null
        rendererInitialized = false

        (root.parent as? ViewGroup)?.removeView(root)
    }

    fun isShowing(): Boolean = attached

    private fun buildUi() {
        root.setBackgroundColor(Color.BLACK)

        rendererContainer.setBackgroundColor(Color.BLACK)
        rendererContainer.setOnTouchListener { _, event ->
            handleTouch(event)
        }
        root.addView(
            rendererContainer,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        status.apply {
            text = "Connected • waiting for screen video…"
            textSize = 13f
            setTextColor(Color.WHITE)
            typeface = Typeface.create(
                "sans-serif-medium",
                Typeface.NORMAL
            )
            setBackgroundColor(
                Color.argb(190, 15, 23, 42)
            )
            setPadding(
                dp(14),
                dp(10),
                dp(14),
                dp(10)
            )
        }
        root.addView(
            status,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP
            ).apply {
                marginStart = dp(12)
                marginEnd = dp(12)
                topMargin = dp(12)
            }
        )

        dock.apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(
                dp(6),
                dp(6),
                dp(6),
                dp(6)
            )
            setBackgroundColor(
                Color.argb(215, 15, 23, 42)
            )
        }

        addButton("Back") {
            session()?.sendBack()
        }
        addButton("Home") {
            session()?.sendHome()
        }
        addButton("Apps") {
            session()?.sendRecents()
        }
        addButton("End") {
            onEnd()
        }

        root.addView(
            dock,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM
            ).apply {
                marginStart = dp(10)
                marginEnd = dp(10)
                bottomMargin = dp(14)
            }
        )
    }

    private fun addButton(
        label: String,
        action: () -> Unit
    ) {
        dock.addView(
            Button(activity).apply {
                text = label
                isAllCaps = false
                setOnClickListener { action() }
            },
            LinearLayout.LayoutParams(
                0,
                dp(48),
                1f
            ).apply {
                marginStart = dp(3)
                marginEnd = dp(3)
            }
        )
    }

    private fun scheduleRendererAttach() {
        if (!attached) return
        val track = remoteTrack ?: return

        rendererContainer.postDelayed(
            {
                if (
                    !attached ||
                    remoteTrack !== track
                ) {
                    return@postDelayed
                }

                if (
                    rendererContainer.width <= 0 ||
                    rendererContainer.height <= 0 ||
                    !rendererContainer.isAttachedToWindow
                ) {
                    scheduleRendererAttach()
                    return@postDelayed
                }

                if (ensureRenderer()) {
                    attachTrack(track)
                } else {
                    status.visibility = View.VISIBLE
                    status.text =
                        "Connected • display is preparing…"
                    rendererContainer.postDelayed(
                        { scheduleRendererAttach() },
                        500L
                    )
                }
            },
            350L
        )
    }

    private fun ensureRenderer(): Boolean {
        if (rendererInitialized) return true

        return runCatching {
            val view =
                renderer ?: SurfaceViewRenderer(activity)
                    .also { created ->
                        renderer = created
                        rendererContainer.addView(
                            created,
                            0,
                            FrameLayout.LayoutParams(
                                FrameLayout.LayoutParams.MATCH_PARENT,
                                FrameLayout.LayoutParams.MATCH_PARENT
                            )
                        )

                        created.holder.addCallback(
                            object :
                                SurfaceHolder.Callback {
                                override fun surfaceCreated(
                                    holder: SurfaceHolder
                                ) {
                                    remoteTrack?.let(
                                        ::attachTrack
                                    )
                                }

                                override fun surfaceChanged(
                                    holder: SurfaceHolder,
                                    format: Int,
                                    width: Int,
                                    height: Int
                                ) = Unit

                                override fun surfaceDestroyed(
                                    holder: SurfaceHolder
                                ) {
                                    sinkTrack?.let {
                                        created.removeSink(
                                            it
                                        )
                                    }
                                    sinkTrack = null
                                }
                            }
                        )
                    }

            view.init(
                WebRtcRuntime.eglBase(
                    activity
                ).eglBaseContext,
                object :
                    RendererCommon.RendererEvents {
                    override fun onFirstFrameRendered() {
                        activity.runOnUiThread {
                            status.visibility =
                                View.GONE
                        }
                    }

                    override fun onFrameResolutionChanged(
                        videoWidth: Int,
                        videoHeight: Int,
                        rotation: Int
                    ) {
                        val rotated =
                            rotation % 180 != 0
                        frameWidth =
                            if (rotated) {
                                videoHeight
                            } else {
                                videoWidth
                            }
                        frameHeight =
                            if (rotated) {
                                videoWidth
                            } else {
                                videoHeight
                            }
                    }
                }
            )

            view.setScalingType(
                RendererCommon.ScalingType
                    .SCALE_ASPECT_FIT
            )
            view.setEnableHardwareScaler(false)
            view.setMirror(false)
            rendererInitialized = true
            true
        }.getOrDefault(false)
    }

    private fun attachTrack(track: VideoTrack) {
        val view = renderer ?: return
        if (!rendererInitialized) return
        if (!view.holder.surface.isValid) return
        if (sinkTrack === track) return

        sinkTrack?.removeSink(view)
        sinkTrack = track
        track.addSink(view)
    }

    private fun handleTouch(event: MotionEvent): Boolean {
        val g = geometry ?: return true
        val s = session() ?: return true

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                downAt = SystemClock.elapsedRealtime()
                return true
            }

            MotionEvent.ACTION_UP -> {
                val start =
                    normalize(
                        downX,
                        downY,
                        g
                    ) ?: return true
                val end =
                    normalize(
                        event.x,
                        event.y,
                        g
                    ) ?: return true

                val duration =
                    (
                        SystemClock.elapsedRealtime() -
                            downAt
                        ).toInt()
                        .coerceIn(80, 2_500)

                val dx = event.x - downX
                val dy = event.y - downY
                val distanceSq = dx * dx + dy * dy

                if (distanceSq < dp(18).toFloat()
                        .let { it * it }
                ) {
                    if (duration >= 600) {
                        s.sendLongPress(
                            start.x,
                            start.y,
                            duration,
                            g.generation
                        )
                    } else {
                        s.sendTap(
                            end.x,
                            end.y,
                            g.generation
                        )
                    }
                } else {
                    s.sendSwipe(
                        start.x,
                        start.y,
                        end.x,
                        end.y,
                        duration,
                        g.generation
                    )
                }
                return true
            }

            MotionEvent.ACTION_CANCEL ->
                return true
        }

        return true
    }

    private fun normalize(
        x: Float,
        y: Float,
        geometry: RemoteGeometry
    ): NormalizedRemotePoint? =
        RemoteViewportMapper.normalize(
            touchX = x,
            touchY = y,
            viewWidth =
                rendererContainer.width.toFloat(),
            viewHeight =
                rendererContainer.height.toFloat(),
            remoteWidth = geometry.widthPx,
            remoteHeight = geometry.heightPx,
            frameWidth =
                frameWidth.takeIf { it > 0 }
                    ?: geometry.widthPx,
            frameHeight =
                frameHeight.takeIf { it > 0 }
                    ?: geometry.heightPx,
            clampToContent = false
        )

    private fun session(): ControllerWebRtcSession? =
        ControllerConnectionRuntime.activeSession(
            sessionId
        )

    private fun dp(value: Int): Int =
        AarisUi.dp(activity, value)
}
