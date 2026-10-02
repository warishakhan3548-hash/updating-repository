package com.aaris.remoteassist.ui

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.aaris.remoteassist.control.GestureStreamPhase
import com.aaris.remoteassist.webrtc.ControllerConnectionRuntime
import com.aaris.remoteassist.webrtc.ControllerWebRtcSession
import com.aaris.remoteassist.webrtc.FallbackVideoFrame
import com.aaris.remoteassist.webrtc.RemoteGeometry
import com.aaris.remoteassist.webrtc.WebRtcRuntime
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.hypot
import kotlin.math.roundToInt
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
    private data class LocalTouchPoint(
        val x: Float,
        val y: Float,
        val atMs: Long
    )
    private val root = FrameLayout(activity)
    private val status = TextView(activity)
    private val dock = LinearLayout(activity)
    private val controlHandle = Button(activity)
    private val rendererContainer = FrameLayout(activity)
    private val fallbackImageView = ImageView(activity)
    private val textureView = TextureView(activity)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val fallbackDecoder =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(
                runnable,
                "AarisFallbackDecoder"
            ).apply {
                priority = Thread.NORM_PRIORITY - 1
            }
        }

    private var eglRenderer: EglRenderer? = null
    private var remoteTrack: VideoTrack? = null
    private var sinkTrack: VideoTrack? = null

    @Volatile
    private var geometry: RemoteGeometry? = null

    @Volatile
    private var frameWidth = 0

    @Volatile
    private var frameHeight = 0

    @Volatile
    private var latestObservedFrameWidth = 0

    @Volatile
    private var latestObservedFrameHeight = 0

    private val touchSlop =
        ViewConfiguration.get(activity).scaledTouchSlop.toFloat()
    private val gesturePoints =
        ArrayList<LocalTouchPoint>(MAX_LOCAL_GESTURE_POINTS)

    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L
    private var gestureGeneration = -1

    private var liveGestureStreamId = 0L
    private var liveGestureStreamActive = false
    private var liveGestureLastEventTime = 0L

    private var multiTouchActive = false
    private var suppressSingleGestureUntilUp = false
    private var firstPointerId = -1
    private var secondPointerId = -1
    private var multiDownAt = 0L
    private var firstStartX = 0f
    private var firstStartY = 0f
    private var secondStartX = 0f
    private var secondStartY = 0f
    private var firstEndX = 0f
    private var firstEndY = 0f
    private var secondEndX = 0f
    private var secondEndY = 0f

    private var handleDownRawX = 0f
    private var handleDownRawY = 0f
    private var handleStartX = 0f
    private var handleStartY = 0f
    private var handleDragging = false
    private var controlHandleUserMoved = false
    private var controlHandleParked = false
    private var controlHandleOnRight = true

    private var attached = false
    @Volatile
    private var fallbackActive = false
    private val lastFallbackFrameId = AtomicLong(-1L)
    private val pendingFallbackFrame =
        AtomicReference<FallbackVideoFrame?>(null)
    private val fallbackDecodeScheduled = AtomicBoolean(false)
    private var fallbackBitmap: Bitmap? = null
    private var mediaRecoveryAttempts = 0
    private var rendererRecoveryAttempts = 0
    private val rawFrameSeen = AtomicBoolean(false)
    private val renderedFrameSeen = AtomicBoolean(false)

    private val controlsAutoHide = Runnable {
        if (attached) {
            setControlsVisible(false)
        }
    }

    private val handlePeek = Runnable {
        if (
            attached &&
            dock.visibility != View.VISIBLE &&
            controlHandle.visibility == View.VISIBLE
        ) {
            parkControlHandle()
        }
    }

    private val interactionIdle = Runnable {
        if (attached) {
            session()?.setInteractionActive(false)
        }
    }

    private val renderSink = VideoSink { frame ->
        val rotatedWidth = frame.rotatedWidth
        val rotatedHeight = frame.rotatedHeight
        latestObservedFrameWidth = rotatedWidth
        latestObservedFrameHeight = rotatedHeight

        val currentGeometry = geometry
        val geometryMatches =
            currentGeometry == null ||
                RemoteViewportMapper.frameMatchesRemote(
                    remoteWidth = currentGeometry.widthPx,
                    remoteHeight = currentGeometry.heightPx,
                    frameWidth = rotatedWidth,
                    frameHeight = rotatedHeight
                )

        if (
            geometryMatches &&
            (
                frameWidth != rotatedWidth ||
                    frameHeight != rotatedHeight
                )
        ) {
            frameWidth = rotatedWidth
            frameHeight = rotatedHeight
            mainHandler.post {
                if (attached) {
                    updateVideoViewport()
                }
            }
        }

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

    private val mediaWatchdog: Runnable =
        object : Runnable {
            override fun run() {
                if (!attached) return

                if (!rawFrameSeen.get()) {
                    if (fallbackActive) {
                        status.visibility = View.VISIBLE
                        status.text =
                            "Compatibility video active • primary stream recovering…"
                        return
                    }

                    if (
                        mediaRecoveryAttempts <
                            MAX_MEDIA_RECOVERY_ATTEMPTS
                    ) {
                        mediaRecoveryAttempts += 1
                        status.visibility = View.VISIBLE
                        status.text =
                            "Connected • video stream recovering…"
                        session()?.requestMediaRecovery()
                        mainHandler.postDelayed(
                            this,
                            MEDIA_RECOVERY_RETRY_MS
                        )
                    } else {
                        status.visibility = View.VISIBLE
                        status.text =
                            "Connected • controls work • waiting for video frames…"
                    }
                    return
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

                        if (rendererRecoveryAttempts == 1) {
                            /*
                             * Decoded WebRTC frames reached this phone, but
                             * the GPU/EGL path is still black. Activate the
                             * independent compatibility pixels as well without
                             * disturbing ICE or the control channel.
                             */
                            session()?.requestMediaRecovery()
                        }

                        rebuildRenderer()
                        mainHandler.postDelayed(
                            this,
                            RENDER_RECOVERY_RETRY_MS
                        )
                    } else {
                        status.visibility = View.VISIBLE
                        status.text =
                            "Video received • display retrying…"
                    }
                }
            }
        }

    private val listener =
        object : ControllerWebRtcSession.Listener {
            override fun onLive(geometry: RemoteGeometry) {
                activity.runOnUiThread {
                    this@InlineRemoteControllerView.geometry =
                        geometry
                    updateVideoViewport()
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
                    } else if (renderedFrameSeen.get()) {
                        status.visibility = View.GONE
                    } else {
                        status.visibility = View.VISIBLE
                        status.text =
                            "Reconnected • restoring remote screen…"
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
                        frameWidth = 0
                        frameHeight = 0
                        latestObservedFrameWidth = 0
                        latestObservedFrameHeight = 0
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

            override fun onFallbackVideoFrame(
                frame: FallbackVideoFrame
            ) {
                decodeFallbackFrame(frame)
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
            updateVideoViewport()
            positionControlHandleIfNeeded()
            ControllerConnectionRuntime.replayUiState(
                sessionId
            )
        }
    }

    fun hide() {
        if (!attached) return
        mainHandler.removeCallbacks(interactionIdle)
        session()?.setInteractionActive(false)
        attached = false

        mainHandler.removeCallbacks(mediaWatchdog)
        mainHandler.removeCallbacks(controlsAutoHide)
        mainHandler.removeCallbacks(handlePeek)
        ControllerConnectionRuntime.detach(listener)
        detachCurrentTrack()
        releaseRenderer()

        fallbackActive = false
        pendingFallbackFrame.set(null)
        fallbackDecoder.shutdownNow()
        activity.runOnUiThread {
            fallbackImageView.setImageDrawable(null)
            fallbackBitmap?.recycle()
            fallbackBitmap = null
        }

        remoteTrack = null
        (root.parent as? ViewGroup)?.removeView(root)
    }

    fun isShowing(): Boolean = attached

    private fun buildUi() {
        root.setBackgroundColor(Color.BLACK)
        root.keepScreenOn = true

        fallbackImageView.apply {
            setBackgroundColor(Color.BLACK)
            scaleType = ImageView.ScaleType.FIT_CENTER
            visibility = View.GONE
            contentDescription = "Remote screen compatibility video"
        }
        rendererContainer.addView(
            fallbackImageView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

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
        rendererContainer.addOnLayoutChangeListener {
                _,
                left,
                top,
                right,
                bottom,
                oldLeft,
                oldTop,
                oldRight,
                oldBottom ->
            val widthChanged =
                right - left != oldRight - oldLeft
            val heightChanged =
                bottom - top != oldBottom - oldTop

            if (widthChanged || heightChanged) {
                updateVideoViewport()
                positionControlHandleIfNeeded()
            }
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

        addButton("Back", autoHide = true) {
            session()?.sendBack()
        }
        addButton("Home", autoHide = true) {
            session()?.sendHome()
        }
        addButton("Apps", autoHide = true) {
            session()?.sendRecents()
        }
        addButton("Hide") {
            setControlsVisible(false)
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

        controlHandle.apply {
            text = "⋮"
            textSize = 22f
            isAllCaps = false
            visibility = View.GONE
            contentDescription =
                "Remote controls. Drag to move this button."
            setOnClickListener {
                setControlsVisible(true)
            }
            setOnTouchListener { view, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        mainHandler.removeCallbacks(handlePeek)
                        view.animate().cancel()
                        view.alpha = 1f
                        controlHandleParked = false
                        controlHandleOnRight =
                            view.x + view.width / 2f >=
                                root.width / 2f
                        handleDownRawX = event.rawX
                        handleDownRawY = event.rawY
                        handleStartX = view.x
                        handleStartY = view.y
                        handleDragging = false
                        true
                    }

                    MotionEvent.ACTION_MOVE -> {
                        val dx = event.rawX - handleDownRawX
                        val dy = event.rawY - handleDownRawY
                        if (
                            !handleDragging &&
                            dx * dx + dy * dy >=
                            touchSlop * touchSlop
                        ) {
                            handleDragging = true
                        }

                        if (handleDragging) {
                            val margin = dp(HANDLE_EDGE_MARGIN_DP).toFloat()
                            val maxX =
                                (root.width - view.width).toFloat() - margin
                            val maxY =
                                (root.height - view.height).toFloat() - margin

                            view.x =
                                (handleStartX + dx).coerceIn(
                                    margin,
                                    maxX.coerceAtLeast(margin)
                                )
                            view.y =
                                (handleStartY + dy).coerceIn(
                                    margin,
                                    maxY.coerceAtLeast(margin)
                                )
                        }
                        true
                    }

                    MotionEvent.ACTION_UP -> {
                        if (handleDragging) {
                            controlHandleUserMoved = true
                            snapControlHandleToNearestEdge()
                        } else {
                            view.performClick()
                        }
                        true
                    }

                    MotionEvent.ACTION_CANCEL -> {
                        handleDragging = false
                        scheduleControlHandlePeek()
                        true
                    }

                    else -> true
                }
            }
        }
        root.addView(
            controlHandle,
            FrameLayout.LayoutParams(
                dp(48),
                dp(48),
                Gravity.TOP or Gravity.START
            )
        )
    }

    private fun setControlsVisible(visible: Boolean) {
        mainHandler.removeCallbacks(controlsAutoHide)
        mainHandler.removeCallbacks(handlePeek)
        dock.visibility =
            if (visible) View.VISIBLE else View.GONE
        controlHandle.visibility =
            if (visible) View.GONE else View.VISIBLE

        if (visible) {
            controlHandleParked = false
            controlHandle.animate().cancel()
            controlHandle.alpha = 1f
            mainHandler.postDelayed(
                controlsAutoHide,
                CONTROLS_AUTO_HIDE_MS
            )
        } else {
            controlHandle.animate().cancel()
            controlHandle.alpha = 1f
            positionControlHandleIfNeeded()
            scheduleControlHandlePeek()
        }
    }

    private fun positionControlHandleIfNeeded() {
        if (
            root.width <= 0 ||
            root.height <= 0 ||
            controlHandle.width <= 0 ||
            controlHandle.height <= 0
        ) {
            return
        }

        val margin = dp(HANDLE_EDGE_MARGIN_DP).toFloat()
        val maxX =
            (root.width - controlHandle.width).toFloat() - margin
        val maxY =
            (root.height - controlHandle.height).toFloat() - margin

        if (!controlHandleUserMoved) {
            controlHandleOnRight = true
            controlHandle.y =
                ((root.height - controlHandle.height) / 2f)
                    .coerceIn(
                        margin,
                        maxY.coerceAtLeast(margin)
                    )
        } else {
            controlHandle.y =
                controlHandle.y.coerceIn(
                    margin,
                    maxY.coerceAtLeast(margin)
                )
            if (!controlHandleParked) {
                controlHandleOnRight =
                    controlHandle.x +
                        controlHandle.width / 2f >=
                        root.width / 2f
            }
        }

        if (controlHandleParked) {
            applyParkedHandlePosition()
        } else {
            controlHandle.x =
                if (controlHandleOnRight) {
                    maxX.coerceAtLeast(margin)
                } else {
                    margin
                }
        }
    }

    private fun snapControlHandleToNearestEdge() {
        if (
            root.width <= 0 ||
            controlHandle.width <= 0
        ) {
            return
        }

        val margin = dp(HANDLE_EDGE_MARGIN_DP).toFloat()
        val left = margin
        val right =
            (
                root.width -
                    controlHandle.width -
                    margin
                ).toFloat()
                .coerceAtLeast(left)
        val center =
            controlHandle.x +
                controlHandle.width / 2f
        controlHandleOnRight =
            center >= root.width / 2f
        controlHandleParked = false

        controlHandle.animate()
            .x(
                if (controlHandleOnRight) {
                    right
                } else {
                    left
                }
            )
            .alpha(1f)
            .setDuration(HANDLE_SNAP_MS)
            .withEndAction {
                scheduleControlHandlePeek()
            }
            .start()
    }

    private fun scheduleControlHandlePeek() {
        mainHandler.removeCallbacks(handlePeek)
        if (
            attached &&
            dock.visibility != View.VISIBLE &&
            controlHandle.visibility == View.VISIBLE
        ) {
            mainHandler.postDelayed(
                handlePeek,
                HANDLE_PEEK_DELAY_MS
            )
        }
    }

    private fun parkControlHandle() {
        if (
            root.width <= 0 ||
            controlHandle.width <= 0 ||
            dock.visibility == View.VISIBLE ||
            controlHandle.visibility != View.VISIBLE
        ) {
            return
        }

        controlHandleOnRight =
            controlHandle.x +
                controlHandle.width / 2f >=
                root.width / 2f
        controlHandleParked = true

        val targetX =
            parkedHandleX()

        controlHandle.animate()
            .x(targetX)
            .alpha(HANDLE_PEEK_ALPHA)
            .setDuration(HANDLE_PEEK_ANIMATION_MS)
            .start()
    }

    private fun applyParkedHandlePosition() {
        if (
            root.width <= 0 ||
            controlHandle.width <= 0
        ) {
            return
        }

        controlHandle.animate().cancel()
        controlHandle.x = parkedHandleX()
        controlHandle.alpha = HANDLE_PEEK_ALPHA
    }

    private fun parkedHandleX(): Float {
        val peek = dp(HANDLE_PEEK_DP).toFloat()
        return if (controlHandleOnRight) {
            root.width.toFloat() - peek
        } else {
            -(controlHandle.width.toFloat() - peek)
        }
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
                                fallbackActive = false
                                textureView.alpha = 1f
                                fallbackImageView.visibility = View.GONE
                                fallbackImageView.setImageDrawable(null)
                                fallbackBitmap?.recycle()
                                fallbackBitmap = null
                                status.visibility = View.GONE
                                session()
                                    ?.confirmPrimaryVideoRendered()

                                /*
                                 * Once the live screen is visible, maximize
                                 * usable remote pixels. The compact side handle
                                 * keeps controls discoverable without covering
                                 * the remote phone's bottom navigation/buttons.
                                 */
                                setControlsVisible(false)
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

    private fun updateVideoViewport() {
        val containerWidth = rendererContainer.width
        val containerHeight = rendererContainer.height
        if (containerWidth <= 0 || containerHeight <= 0) return

        val currentGeometry = geometry
        val useFrame =
            currentGeometry != null &&
                frameWidth > 0 &&
                frameHeight > 0 &&
                RemoteViewportMapper.frameMatchesRemote(
                    remoteWidth = currentGeometry.widthPx,
                    remoteHeight = currentGeometry.heightPx,
                    frameWidth = frameWidth,
                    frameHeight = frameHeight
                )

        val contentWidth =
            if (useFrame) {
                frameWidth
            } else {
                currentGeometry?.widthPx ?: return
            }
        val contentHeight =
            if (useFrame) {
                frameHeight
            } else {
                currentGeometry?.heightPx ?: return
            }
        if (contentWidth <= 0 || contentHeight <= 0) return

        val contentAspect =
            contentWidth.toFloat() / contentHeight.toFloat()
        val containerAspect =
            containerWidth.toFloat() / containerHeight.toFloat()

        val targetWidth: Int
        val targetHeight: Int
        if (containerAspect > contentAspect) {
            targetHeight = containerHeight
            targetWidth =
                (targetHeight * contentAspect)
                    .roundToInt()
                    .coerceAtLeast(1)
        } else {
            targetWidth = containerWidth
            targetHeight =
                (targetWidth / contentAspect)
                    .roundToInt()
                    .coerceAtLeast(1)
        }

        val params =
            (textureView.layoutParams as? FrameLayout.LayoutParams)
                ?: FrameLayout.LayoutParams(
                    targetWidth,
                    targetHeight
                )
        if (
            params.width != targetWidth ||
            params.height != targetHeight ||
            params.gravity != Gravity.CENTER
        ) {
            params.width = targetWidth
            params.height = targetHeight
            params.gravity = Gravity.CENTER
            textureView.layoutParams = params
        }

        updateRendererAspect(targetWidth, targetHeight)
        positionControlHandleIfNeeded()
    }

    private fun decodeFallbackFrame(
        frame: FallbackVideoFrame
    ) {
        if (
            !attached ||
            renderedFrameSeen.get()
        ) {
            return
        }

        while (true) {
            val previous = lastFallbackFrameId.get()
            if (frame.frameId <= previous) {
                return
            }
            if (
                lastFallbackFrameId.compareAndSet(
                    previous,
                    frame.frameId
                )
            ) {
                break
            }
        }

        /*
         * Compatibility video is best-effort. Never let JPEG decode build an
         * old-frame backlog: retain only the newest not-yet-decoded frame.
         */
        pendingFallbackFrame.set(
            frame.copy(
                jpeg = frame.jpeg.copyOf()
            )
        )
        scheduleFallbackDecode()
    }

    private fun scheduleFallbackDecode() {
        if (
            !attached ||
            renderedFrameSeen.get() ||
            !fallbackDecodeScheduled.compareAndSet(
                false,
                true
            )
        ) {
            return
        }

        runCatching {
            fallbackDecoder.execute {
                drainFallbackFrames()
            }
        }.onFailure {
            fallbackDecodeScheduled.set(false)
        }
    }

    private fun drainFallbackFrames() {
        try {
            while (
                attached &&
                !renderedFrameSeen.get()
            ) {
                val frame =
                    pendingFallbackFrame.getAndSet(null)
                        ?: break
                decodeFallbackFrameNow(frame)
            }
        } finally {
            fallbackDecodeScheduled.set(false)
            if (
                attached &&
                !renderedFrameSeen.get() &&
                pendingFallbackFrame.get() != null
            ) {
                scheduleFallbackDecode()
            }
        }
    }

    private fun decodeFallbackFrameNow(
        frame: FallbackVideoFrame
    ) {
        val decoded = BitmapFactory.decodeByteArray(
            frame.jpeg,
            0,
            frame.jpeg.size
        ) ?: return

        val oriented =
            if (frame.rotation == 0) {
                decoded
            } else {
                runCatching {
                    val matrix = Matrix().apply {
                        postRotate(
                            frame.rotation.toFloat()
                        )
                    }
                    Bitmap.createBitmap(
                        decoded,
                        0,
                        0,
                        decoded.width,
                        decoded.height,
                        matrix,
                        true
                    )
                }.getOrNull()?.also {
                    if (it !== decoded) {
                        decoded.recycle()
                    }
                } ?: decoded
            }

        /*
         * If a newer fallback frame arrived while this JPEG was decoding,
         * skip presenting the stale bitmap. The next loop iteration decodes
         * the newest frame directly.
         */
        if (
            frame.frameId < lastFallbackFrameId.get() &&
            pendingFallbackFrame.get() != null
        ) {
            oriented.recycle()
            return
        }

        activity.runOnUiThread {
            if (
                !attached ||
                renderedFrameSeen.get()
            ) {
                oriented.recycle()
                return@runOnUiThread
            }

            latestObservedFrameWidth = oriented.width
            latestObservedFrameHeight = oriented.height

            val currentGeometry = geometry
            if (
                currentGeometry != null &&
                !RemoteViewportMapper.frameMatchesRemote(
                    remoteWidth = currentGeometry.widthPx,
                    remoteHeight = currentGeometry.heightPx,
                    frameWidth = oriented.width,
                    frameHeight = oriented.height
                )
            ) {
                oriented.recycle()
                return@runOnUiThread
            }

            fallbackActive = true
            frameWidth = oriented.width
            frameHeight = oriented.height
            updateVideoViewport()

            val previous = fallbackBitmap
            fallbackBitmap = oriented
            fallbackImageView.setImageBitmap(oriented)
            fallbackImageView.visibility = View.VISIBLE
            textureView.alpha = 0f

            if (
                previous != null &&
                previous !== oriented &&
                !previous.isRecycled
            ) {
                previous.recycle()
            }

            status.visibility = View.VISIBLE
            status.text =
                "Compatibility video active • primary stream recovering…"
        }
    }

    private fun addButton(
        label: String,
        autoHide: Boolean = false,
        action: () -> Unit
    ) {
        dock.addView(
            Button(activity).apply {
                text = label
                isAllCaps = false
                setOnClickListener {
                    if (autoHide) {
                        beginRemoteMotion()
                    }
                    action()
                    if (autoHide) {
                        scheduleRemoteMotionIdle()
                        setControlsVisible(false)
                    }
                }
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
                beginRemoteMotion()
                resetLiveGestureStream()
                suppressSingleGestureUntilUp = false
                multiTouchActive = false
                downX = event.x
                downY = event.y
                downAt = event.eventTime
                gestureGeneration = g.generation
                gesturePoints.clear()
                appendGesturePoint(
                    event.x,
                    event.y,
                    event.eventTime
                )
                return true
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                if (
                    event.pointerCount >= 2 &&
                    !multiTouchActive
                ) {
                    if (
                        liveGestureStreamActive &&
                        g.generation == gestureGeneration
                    ) {
                        endLiveGestureStream(
                            session = s,
                            geometry = g,
                            x = event.getX(0),
                            y = event.getY(0),
                            eventTime = event.eventTime
                        )
                    } else {
                        resetLiveGestureStream()
                    }

                    val firstIndex = 0
                    val secondIndex = event.actionIndex
                    firstPointerId =
                        event.getPointerId(firstIndex)
                    secondPointerId =
                        event.getPointerId(secondIndex)
                    firstStartX = event.getX(firstIndex)
                    firstStartY = event.getY(firstIndex)
                    secondStartX = event.getX(secondIndex)
                    secondStartY = event.getY(secondIndex)
                    firstEndX = firstStartX
                    firstEndY = firstStartY
                    secondEndX = secondStartX
                    secondEndY = secondStartY
                    multiDownAt = event.eventTime
                    gestureGeneration = g.generation
                    multiTouchActive = true
                    suppressSingleGestureUntilUp = true
                    gesturePoints.clear()
                }
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                if (multiTouchActive) {
                    updateMultiTouch(event)
                } else if (!suppressSingleGestureUntilUp) {
                    for (index in 0 until event.historySize) {
                        appendGesturePoint(
                            event.getHistoricalX(index),
                            event.getHistoricalY(index),
                            event.getHistoricalEventTime(index)
                        )
                    }
                    appendGesturePoint(
                        event.x,
                        event.y,
                        event.eventTime
                    )
                    streamSingleGestureIfNeeded(
                        session = s,
                        geometry = g,
                        event = event
                    )
                }
                return true
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (multiTouchActive) {
                    updateMultiTouch(event)
                    if (g.generation == gestureGeneration) {
                        sendMultiTouchGesture(s, g)
                    }
                    resetMultiTouch()
                    suppressSingleGestureUntilUp = true
                    scheduleRemoteMotionIdle()
                }
                return true
            }

            MotionEvent.ACTION_UP -> {
                if (multiTouchActive) {
                    updateMultiTouch(event)
                    if (g.generation == gestureGeneration) {
                        sendMultiTouchGesture(s, g)
                    }
                    resetMultiTouch()
                    resetLiveGestureStream()
                    gesturePoints.clear()
                    suppressSingleGestureUntilUp = false
                    scheduleRemoteMotionIdle()
                    return true
                }

                if (suppressSingleGestureUntilUp) {
                    suppressSingleGestureUntilUp = false
                    resetLiveGestureStream()
                    gesturePoints.clear()
                    scheduleRemoteMotionIdle()
                    return true
                }

                if (g.generation != gestureGeneration) {
                    resetLiveGestureStream()
                    gesturePoints.clear()
                    scheduleRemoteMotionIdle()
                    return true
                }

                appendGesturePoint(
                    event.x,
                    event.y,
                    event.eventTime
                )

                if (liveGestureStreamActive) {
                    endLiveGestureStream(
                        session = s,
                        geometry = g,
                        x = event.x,
                        y = event.y,
                        eventTime = event.eventTime
                    )
                } else {
                    finishSingleGesture(
                        session = s,
                        geometry = g,
                        upX = event.x,
                        upY = event.y
                    )
                }

                gesturePoints.clear()
                scheduleRemoteMotionIdle()
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                if (
                    liveGestureStreamActive &&
                    g.generation == gestureGeneration
                ) {
                    endLiveGestureStream(
                        session = s,
                        geometry = g,
                        x = event.x,
                        y = event.y,
                        eventTime = event.eventTime
                    )
                } else {
                    resetLiveGestureStream()
                }
                mainHandler.removeCallbacks(interactionIdle)
                s.setInteractionActive(false)
                gesturePoints.clear()
                resetMultiTouch()
                suppressSingleGestureUntilUp = false
                return true
            }
        }

        return true
    }

    private fun streamSingleGestureIfNeeded(
        session: ControllerWebRtcSession,
        geometry: RemoteGeometry,
        event: MotionEvent
    ) {
        if (geometry.generation != gestureGeneration) {
            return
        }

        if (!liveGestureStreamActive) {
            val distance =
                hypot(
                    event.x - downX,
                    event.y - downY
                )
            if (distance < touchSlop) {
                return
            }

            val start =
                normalize(
                    x = downX,
                    y = downY,
                    geometry = geometry,
                    clampToContent = false
                ) ?: return
            val current =
                normalize(
                    x = event.x,
                    y = event.y,
                    geometry = geometry,
                    clampToContent = true
                ) ?: return
            val streamId = session.newGestureStreamId()
            val sent =
                session.sendGestureStreamSegment(
                    streamId = streamId,
                    phase = GestureStreamPhase.START,
                    points = listOf(
                        start.x to start.y,
                        current.x to current.y
                    ),
                    durationMs =
                        streamSegmentDuration(
                            event.eventTime - downAt
                        ),
                    expectedGeneration =
                        geometry.generation
                )

            if (sent) {
                liveGestureStreamId = streamId
                liveGestureStreamActive = true
                liveGestureLastEventTime =
                    event.eventTime
            }
            return
        }

        val elapsed =
            event.eventTime -
                liveGestureLastEventTime
        if (elapsed < STREAM_SEGMENT_INTERVAL_MS) {
            return
        }

        val current =
            normalize(
                x = event.x,
                y = event.y,
                geometry = geometry,
                clampToContent = true
            ) ?: return

        val sent =
            session.sendGestureStreamSegment(
                streamId = liveGestureStreamId,
                phase = GestureStreamPhase.CONTINUE,
                points = listOf(
                    current.x to current.y
                ),
                durationMs =
                    streamSegmentDuration(elapsed),
                expectedGeneration =
                    geometry.generation
            )
        if (sent) {
            liveGestureLastEventTime =
                event.eventTime
        }
    }

    private fun endLiveGestureStream(
        session: ControllerWebRtcSession,
        geometry: RemoteGeometry,
        x: Float,
        y: Float,
        eventTime: Long
    ) {
        if (!liveGestureStreamActive) {
            resetLiveGestureStream()
            return
        }

        val point =
            normalize(
                x = x,
                y = y,
                geometry = geometry,
                clampToContent = true
            )
        if (point != null) {
            session.sendGestureStreamSegment(
                streamId = liveGestureStreamId,
                phase = GestureStreamPhase.END,
                points = listOf(
                    point.x to point.y
                ),
                durationMs =
                    streamSegmentDuration(
                        eventTime -
                            liveGestureLastEventTime
                    ),
                expectedGeneration =
                    geometry.generation
            )
        }

        resetLiveGestureStream()
    }

    private fun resetLiveGestureStream() {
        liveGestureStreamId = 0L
        liveGestureStreamActive = false
        liveGestureLastEventTime = 0L
    }

    private fun streamSegmentDuration(
        elapsedMs: Long
    ): Int =
        elapsedMs.toInt().coerceIn(
            MIN_STREAM_SEGMENT_MS,
            MAX_STREAM_SEGMENT_MS
        )

    private fun beginRemoteMotion() {
        mainHandler.removeCallbacks(interactionIdle)
        session()?.setInteractionActive(true)
    }

    private fun scheduleRemoteMotionIdle() {
        mainHandler.removeCallbacks(interactionIdle)
        if (attached) {
            mainHandler.postDelayed(
                interactionIdle,
                REMOTE_MOTION_TAIL_MS
            )
        }
    }

    private fun finishSingleGesture(
        session: ControllerWebRtcSession,
        geometry: RemoteGeometry,
        upX: Float,
        upY: Float
    ) {
        val rawDuration =
            (
                SystemClock.elapsedRealtime() -
                    downAt
                ).toInt()
                .coerceIn(1, 2_500)
        val dx = upX - downX
        val dy = upY - downY
        val distance = hypot(dx, dy)

        if (distance < touchSlop) {
            val point =
                normalize(
                    x = upX,
                    y = upY,
                    geometry = geometry,
                    clampToContent = false
                ) ?: return

            if (
                rawDuration >=
                ViewConfiguration.getLongPressTimeout()
            ) {
                session.sendLongPress(
                    point.x,
                    point.y,
                    rawDuration.coerceIn(450, 1_500),
                    geometry.generation
                )
            } else {
                session.sendTap(
                    point.x,
                    point.y,
                    geometry.generation
                )
            }
            return
        }

        val start =
            normalize(
                x = downX,
                y = downY,
                geometry = geometry,
                clampToContent = false
            ) ?: return
        val end =
            normalize(
                x = upX,
                y = upY,
                geometry = geometry,
                clampToContent = true
            ) ?: return
        val duration =
            latencyOptimizedGestureDuration(rawDuration)

        val path = sampledGesturePoints()
            .mapIndexedNotNull { index, point ->
                normalize(
                    x = point.x,
                    y = point.y,
                    geometry = geometry,
                    clampToContent = index != 0
                )
            }

        if (path.size >= 3) {
            session.sendGesturePath(
                points = path.map { it.x to it.y },
                durationMs = duration,
                expectedGeneration = geometry.generation
            )
        } else {
            session.sendSwipe(
                fromNx = start.x,
                fromNy = start.y,
                toNx = end.x,
                toNy = end.y,
                durationMs = duration,
                expectedGeneration = geometry.generation
            )
        }
    }

    private fun appendGesturePoint(
        x: Float,
        y: Float,
        atMs: Long
    ) {
        if (!x.isFinite() || !y.isFinite()) return

        val previous = gesturePoints.lastOrNull()
        if (previous != null) {
            val distance =
                hypot(
                    x - previous.x,
                    y - previous.y
                )
            val elapsed = atMs - previous.atMs
            if (
                distance < touchSlop * 0.45f &&
                elapsed < TOUCH_SAMPLE_INTERVAL_MS
            ) {
                return
            }
        }

        if (gesturePoints.size < MAX_LOCAL_GESTURE_POINTS) {
            gesturePoints +=
                LocalTouchPoint(
                    x = x,
                    y = y,
                    atMs = atMs
                )
        } else {
            gesturePoints[gesturePoints.lastIndex] =
                LocalTouchPoint(
                    x = x,
                    y = y,
                    atMs = atMs
                )
        }
    }

    private fun sampledGesturePoints(): List<LocalTouchPoint> {
        if (gesturePoints.size <= MAX_GESTURE_POINTS) {
            return gesturePoints.toList()
        }

        val result =
            ArrayList<LocalTouchPoint>(MAX_GESTURE_POINTS)
        val lastIndex = gesturePoints.lastIndex
        for (index in 0 until MAX_GESTURE_POINTS) {
            val sourceIndex =
                (
                    index.toLong() *
                        lastIndex /
                        (MAX_GESTURE_POINTS - 1)
                    ).toInt()
            result += gesturePoints[sourceIndex]
        }
        return result
    }

    private fun updateMultiTouch(event: MotionEvent) {
        val firstIndex =
            event.findPointerIndex(firstPointerId)
        val secondIndex =
            event.findPointerIndex(secondPointerId)

        if (firstIndex >= 0) {
            firstEndX = event.getX(firstIndex)
            firstEndY = event.getY(firstIndex)
        }
        if (secondIndex >= 0) {
            secondEndX = event.getX(secondIndex)
            secondEndY = event.getY(secondIndex)
        }
    }

    private fun sendMultiTouchGesture(
        session: ControllerWebRtcSession,
        geometry: RemoteGeometry
    ) {
        val firstStart =
            normalize(
                firstStartX,
                firstStartY,
                geometry,
                clampToContent = false
            ) ?: return
        val secondStart =
            normalize(
                secondStartX,
                secondStartY,
                geometry,
                clampToContent = false
            ) ?: return
        val firstEnd =
            normalize(
                firstEndX,
                firstEndY,
                geometry,
                clampToContent = true
            ) ?: return
        val secondEnd =
            normalize(
                secondEndX,
                secondEndY,
                geometry,
                clampToContent = true
            ) ?: return

        val rawDuration =
            (
                SystemClock.elapsedRealtime() -
                    multiDownAt
                ).toInt()
                .coerceIn(80, 2_500)

        session.sendTwoFingerGesture(
            firstFromNx = firstStart.x,
            firstFromNy = firstStart.y,
            firstToNx = firstEnd.x,
            firstToNy = firstEnd.y,
            secondFromNx = secondStart.x,
            secondFromNy = secondStart.y,
            secondToNx = secondEnd.x,
            secondToNy = secondEnd.y,
            durationMs =
                latencyOptimizedGestureDuration(rawDuration),
            expectedGeneration = geometry.generation
        )
    }

    private fun resetMultiTouch() {
        multiTouchActive = false
        firstPointerId = -1
        secondPointerId = -1
    }

    private fun latencyOptimizedGestureDuration(
        rawDurationMs: Int
    ): Int =
        rawDurationMs.coerceIn(
            MIN_REMOTE_GESTURE_MS,
            MAX_REMOTE_GESTURE_MS
        )

    private fun normalize(
        x: Float,
        y: Float,
        geometry: RemoteGeometry,
        clampToContent: Boolean = false
    ): NormalizedRemotePoint? {
        val observedWidth = latestObservedFrameWidth
        val observedHeight = latestObservedFrameHeight
        if (
            observedWidth > 0 &&
            observedHeight > 0 &&
            !RemoteViewportMapper.frameMatchesRemote(
                remoteWidth = geometry.widthPx,
                remoteHeight = geometry.heightPx,
                frameWidth = observedWidth,
                frameHeight = observedHeight
            )
        ) {
            /*
             * Rotation changes the visible pixels before HELLO can rotate the
             * logical control generation. Reject that tiny stale window rather
             * than risk injecting a tap at the wrong physical coordinate.
             */
            return null
        }

        val candidateFrameWidth =
            frameWidth.takeIf {
                it > 0 &&
                    RemoteViewportMapper.frameMatchesRemote(
                        remoteWidth = geometry.widthPx,
                        remoteHeight = geometry.heightPx,
                        frameWidth = it,
                        frameHeight =
                            frameHeight.takeIf { value -> value > 0 }
                                ?: geometry.heightPx
                    )
            } ?: geometry.widthPx
        val candidateFrameHeight =
            if (candidateFrameWidth == geometry.widthPx) {
                geometry.heightPx
            } else {
                frameHeight
            }

        return RemoteViewportMapper.normalize(
            touchX = x,
            touchY = y,
            viewWidth =
                rendererContainer.width.toFloat(),
            viewHeight =
                rendererContainer.height.toFloat(),
            remoteWidth = geometry.widthPx,
            remoteHeight = geometry.heightPx,
            frameWidth = candidateFrameWidth,
            frameHeight = candidateFrameHeight,
            clampToContent = clampToContent
        )
    }

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

        private const val CONTROLS_AUTO_HIDE_MS = 5_000L
        private const val HANDLE_EDGE_MARGIN_DP = 8
        private const val HANDLE_SNAP_MS = 140L
        private const val HANDLE_PEEK_DELAY_MS = 650L
        private const val HANDLE_PEEK_ANIMATION_MS = 120L
        private const val HANDLE_PEEK_DP = 10
        private const val HANDLE_PEEK_ALPHA = 0.46f
        private const val REMOTE_MOTION_TAIL_MS = 1_400L

        private const val STREAM_SEGMENT_INTERVAL_MS = 48L
        private const val MIN_STREAM_SEGMENT_MS = 24
        private const val MAX_STREAM_SEGMENT_MS = 72

        private const val TOUCH_SAMPLE_INTERVAL_MS = 24L
        private const val MAX_LOCAL_GESTURE_POINTS = 192
        private const val MAX_GESTURE_POINTS = 64
        private const val MIN_REMOTE_GESTURE_MS = 80
        private const val MAX_REMOTE_GESTURE_MS = 650
    }
}
