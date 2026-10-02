package com.aaris.remoteassist.ui

import android.app.Activity
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.TextureView
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
import java.util.concurrent.atomic.AtomicBoolean
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.GlRectDrawer
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack

/**
 * Full-screen controller UI that lives inside MainActivity.
 *
 * WebRTC remains owned by ControllerConnectionService. This view uses a
 * TextureView-backed EglRenderer so the remote video participates in the same
 * Android view hierarchy as the controls instead of depending on a separate
 * SurfaceView window/layer.
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
    private val textureView = TextureView(activity)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eglRenderer: EglRenderer? = null
    private var remoteTrack: VideoTrack? = null
    private var sinkTrack: VideoTrack? = null
    private var geometry: RemoteGeometry? = null
    private var frameWidth = 0
    private var frameHeight = 0

    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L

    private var attached = false
    private var mediaRecoveryAttempts = 0
    private var rendererRecoveryAttempts = 0
    private val rawFrameSeen = AtomicBoolean(false)
    private val renderedFrameSeen = AtomicBoolean(false)

    private val renderSink = VideoSink { frame ->
        frameWidth = frame.rotatedWidth
        frameHeight = frame.rotatedHeight

        if (rawFrameSeen.compareAndSet(false, true)) {
            activity.runOnUiThread {
                if (attached) {
                    status.visibility = View.VISIBLE
                    status.text =
                        "Remote video frames received • rendering…"
                }
            }
        }

        eglRenderer?.onFrame(frame)
    }

    private val mediaWatchdog = Runnable {
        if (!attached) return@Runnable

        if (!rawFrameSeen.get()) {
            if (mediaRecoveryAttempts < MAX_MEDIA_RECOVERY_ATTEMPTS) {
                mediaRecoveryAttempts += 1
                status.visibility = View.VISIBLE
                status.text =
                    "Connected • video stream recovering…"
                session()?.requestMediaRecovery()
                mainHandler.postDelayed(
                    mediaWatchdog,
                    MEDIA_RECOVERY_RETRY_MS
                )
            } else {
                status.visibility = View.VISIBLE
                status.text =
                    "Connected • controls work • waiting for video frames…"
            }
            return@Runnable
        }

        if (!renderedFrameSeen.get()) {
            if (
                rendererRecoveryAttempts <
                    MAX_RENDERER_RECOVERY_ATTEMPTS
            ) {
                rendererRecoveryAttempts += 1
                status.visibility = View.VISIBLE
                status.text =
                    "Video frames are here • rebuilding display…"
                rebuildRenderer()
                mainHandler.postDelayed(
                    mediaWatchdog,
                    RENDER_RECOVERY_RETRY_MS
                )
            } else {
                status.visibility = View.VISIBLE
                status.text =
                    "Video received • display retrying…"
            }
        }
    }

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
                        detachCurrentTrack()
                        remoteTrack = track
                        track.setEnabled(true)
                        rawFrameSeen.set(false)
                        renderedFrameSeen.set(false)
                        mediaRecoveryAttempts = 0
                        rendererRecoveryAttempts = 0
                    }

                    status.visibility = View.VISIBLE
                    status.text =
                        "Video connected • opening remote screen…"

                    ensureRenderer()
                    attachTrack(track)

                    mainHandler.removeCallbacks(mediaWatchdog)
                    mainHandler.postDelayed(
                        mediaWatchdog,
                        FIRST_FRAME_DEADLINE_MS
                    )
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
            ensureRenderer()
            ControllerConnectionRuntime.replayUiState(
                sessionId
            )
        }
    }

    fun hide() {
        if (!attached) return
        attached = false

        mainHandler.removeCallbacks(mediaWatchdog)
        ControllerConnectionRuntime.detach(listener)
        detachCurrentTrack()
        releaseRenderer()

        remoteTrack = null
        (root.parent as? ViewGroup)?.removeView(root)
    }

    fun isShowing(): Boolean = attached

    private fun buildUi() {
        root.setBackgroundColor(Color.BLACK)

        textureView.isOpaque = true
        textureView.surfaceTextureListener =
            object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int
                ) {
                    ensureRenderer()
                    eglRenderer?.createEglSurface(surface)
                    updateRendererAspect(width, height)
                    remoteTrack?.let(::attachTrack)
                }

                override fun onSurfaceTextureSizeChanged(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int
                ) {
                    updateRendererAspect(width, height)
                }

                override fun onSurfaceTextureDestroyed(
                    surface: SurfaceTexture
                ): Boolean {
                    eglRenderer?.releaseEglSurface {}
                    return true
                }

                override fun onSurfaceTextureUpdated(
                    surface: SurfaceTexture
                ) = Unit
            }

        rendererContainer.setBackgroundColor(Color.BLACK)
        rendererContainer.setOnTouchListener { _, event ->
            handleTouch(event)
        }
        rendererContainer.addView(
            textureView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

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

    private fun ensureRenderer(): Boolean {
        if (eglRenderer != null) return true

        return runCatching {
            val renderer = EglRenderer("AarisInlineRemote")
            renderer.init(
                WebRtcRuntime.eglBase(activity)
                    .eglBaseContext,
                EglBase.CONFIG_PLAIN,
                GlRectDrawer()
            )
            renderer.setMirror(false)
            renderer.disableFpsReduction()
            updateRendererAspect(
                textureView.width,
                textureView.height,
                renderer
            )
            renderer.addFrameListener(
                {
                    if (
                        renderedFrameSeen.compareAndSet(
                            false,
                            true
                        )
                    ) {
                        activity.runOnUiThread {
                            if (attached) {
                                status.visibility = View.GONE
                            }
                        }
                    }
                },
                0f
            )

            eglRenderer = renderer

            if (textureView.isAvailable) {
                textureView.surfaceTexture?.let(
                    renderer::createEglSurface
                )
            }

            true
        }.getOrDefault(false)
    }

    private fun rebuildRenderer() {
        detachCurrentTrack()
        releaseRenderer()
        renderedFrameSeen.set(false)

        rendererContainer.postDelayed(
            {
                if (!attached) return@postDelayed
                ensureRenderer()
                remoteTrack?.let(::attachTrack)
            },
            250L
        )
    }

    private fun releaseRenderer() {
        val renderer = eglRenderer ?: return
        eglRenderer = null
        runCatching {
            renderer.releaseEglSurface {}
        }
        runCatching { renderer.release() }
    }

    private fun attachTrack(track: VideoTrack) {
        if (!attached) return
        if (!ensureRenderer()) return
        if (sinkTrack === track) return

        detachCurrentTrack()
        sinkTrack = track
        track.addSink(renderSink)
    }

    private fun detachCurrentTrack() {
        val track = sinkTrack
        if (track != null) {
            runCatching {
                track.removeSink(renderSink)
            }
        }
        sinkTrack = null
    }

    private fun updateRendererAspect(
        width: Int,
        height: Int,
        renderer: EglRenderer? = eglRenderer
    ) {
        if (width <= 0 || height <= 0) return
        renderer?.setLayoutAspectRatio(
            width.toFloat() / height.toFloat()
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

                if (
                    distanceSq <
                        dp(18).toFloat()
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

    companion object {
        private const val FIRST_FRAME_DEADLINE_MS = 3_500L
        private const val MEDIA_RECOVERY_RETRY_MS = 4_000L
        private const val RENDER_RECOVERY_RETRY_MS = 2_500L
        private const val MAX_MEDIA_RECOVERY_ATTEMPTS = 2
        private const val MAX_RENDERER_RECOVERY_ATTEMPTS = 2
    }
}
