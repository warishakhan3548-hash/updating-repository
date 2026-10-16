package com.aaris.remoteassist.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.aaris.remoteassist.control.GestureStreamPhase
import com.aaris.remoteassist.webrtc.ControllerConnectionRuntime
import com.aaris.remoteassist.webrtc.ControllerWebRtcSession
import com.aaris.remoteassist.webrtc.FallbackDeltaFrame
import com.aaris.remoteassist.webrtc.FallbackDeltaPatch
import com.aaris.remoteassist.webrtc.FallbackVideoFrame
import com.aaris.remoteassist.webrtc.PassiveMotionPriority
import com.aaris.remoteassist.webrtc.RemoteGeometry
import com.aaris.remoteassist.webrtc.PresentationCadenceTracker
import com.aaris.remoteassist.webrtc.RealtimeMediaPolicy
import com.aaris.remoteassist.webrtc.WebRtcRuntime
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.hypot
import kotlin.math.roundToInt
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.EglThread
import org.webrtc.GlRectDrawer
import org.webrtc.ThreadUtils
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack

/**
 * Full-screen controller UI that lives inside MainActivity.
 *
 * WebRTC remains owned by ControllerConnectionService. The remote video is
 * presented through a SurfaceView-backed EglRenderer so SurfaceFlinger can use
 * the direct composition path instead of routing every frame through a
 * TextureView layer. Controls and recovery pixels stay in the app window above
 * the default below-window video surface.
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

    private data class DecodedDeltaPatch(
        val x: Int,
        val y: Int,
        val bitmap: Bitmap
    )

    private data class DeferredFallbackDelta(
        val anchorFrameId: Long,
        val frame: FallbackDeltaFrame
    )

    private val root = FrameLayout(activity)
    private val status = TextView(activity)
    private val dock = LinearLayout(activity)
    private val controlHandle = Button(activity)
    private val rendererContainer = FrameLayout(activity)
    private val fallbackImageView = ImageView(activity)
    private val surfaceView = SurfaceView(activity)
    private val touchFeedback = RemoteTouchFeedback(activity)
    @Volatile private var videoStats = "Video stats: waiting for transport"
    @Volatile private var inputStats = "Command ACK: waiting for applied input"
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

    // RenderListener runs on EGL while lifecycle transitions run on the UI thread.
    @Volatile
    private var eglRenderer: EglRenderer? = null
    private var renderEglThread: EglThread? = null
    private var renderTouchPriorityActive = false
    private var renderPassivePriorityActive = false
    private var renderInteractionPriorityActive = false
    @Volatile
    private var rendererSurfaceAttached = false
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
    private val gestureStreamPacer = GestureStreamPacer()
    private val presentationCadence = PresentationCadenceTracker()
    // Only an O(1) counter crosses the decoder/EGL thread boundary. It lets
    // glass telemetry exclude producer-idle gaps without hiding a renderer
    // stall during which decoded frames kept arriving.
    private val decodedFrameSequence = AtomicLong(0L)
    /*
     * The host already keeps capture scheduling elevated while natural screen
     * motion continues after finger-up (fling/video/game animation). Mirror that
     * policy at the final glass stage: real EGL swaps are authoritative evidence
     * that the controller still has moving pixels to present.
     *
     * This does not synthesize InteractionState, request more frames or add a
     * decoded-frame queue. It only keeps the existing EglRenderer thread at
     * display priority while measured presentation remains active.
     */
    private val passiveRenderMotion =
        PassiveMotionPriority(
            tailMs = PASSIVE_RENDER_PRIORITY_TAIL_MS
        )
    private val lastPresentationHeartbeatAtMs =
        AtomicLong(Long.MIN_VALUE / 2)
    private val surfaceFrameRateHints = SurfaceFrameRateHintGovernor()
    private val primaryConfirmation = PrimaryVideoConfirmation()

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
    private var handleDownAt = 0L
    private var handleDragging = false
    private var handleWasParkedOnDown = false
    private var controlHandleUserMoved = false
    private var controlHandleParked = false
    private var controlHandleOnRight = true

    private var attached = false
    private var previousLegacySystemUiVisibility: Int? = null
    private var previousRequestedOrientation: Int? = null
    private var immersiveModeApplied = false

    @Volatile
    private var fallbackActive = false

    private val lastFallbackFrameId = AtomicLong(-1L)
    private val pendingFallbackFrame =
        AtomicReference<FallbackVideoFrame?>(null)
    private val fallbackDecodeScheduled = AtomicBoolean(false)
    private val deltaFramesInFlight = AtomicInteger(0)
    private val fallbackAdmissionLock = Any()
    private var activeFallbackAnchorId = -1L
    private val deferredFallbackDeltas = ArrayDeque<DeferredFallbackDelta>()
    private var lastAnchorRequestMs = 0L
    private var fallbackBitmap: Bitmap? = null
    private var fallbackScratchBitmap: Bitmap? = null
    @Volatile
    private var fallbackCompositeFrameId = -1L
    private var mediaRecoveryAttempts = 0
    private var rendererRecoveryAttempts = 0
    private var mediaWatchdogArmed = false
    private val rawFrameSeen = AtomicBoolean(false)
    @Volatile private var lastRawFrameAtMs = 0L
    @Volatile private var lastPresentedFrameAtMs = 0L
    private val renderedFrameSeen = AtomicBoolean(false)
    private val renderConfirmationGeneration = AtomicLong(-1L)
    private val recoveryGeneration = AtomicLong(0L)
    private var imageDisplayed = false

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
            endRemoteMotion()
        }
    }

    private val passiveRenderPriorityExpiry = Runnable {
        val now = android.os.SystemClock.elapsedRealtime()
        setRenderPassivePriority(
            attached &&
                passiveRenderMotion.isActive(now)
        )
    }

    private val renderSink = VideoSink { frame ->
        /*
         * Decoded pixels are latency-critical. Hand the texture to EglRenderer
         * before geometry/status bookkeeping so app-side work can never sit in
         * front of the newest frame. EglRenderer remains latest-frame-wins; no
         * extra queue, copy or presentation clock is introduced here.
         */
        eglRenderer?.let { renderer ->
            // Count before handing the frame to the EGL thread: a very fast
            // buffer swap must never observe an older decoder sequence.
            decodedFrameSequence.incrementAndGet()
            renderer.onFrame(frame)
        }

        lastRawFrameAtMs = android.os.SystemClock.elapsedRealtime()
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
                    showVideoStatus("Remote video frames received • rendering…")
                }
            }
        }

    }

    private val mediaWatchdog: Runnable =
        object : Runnable {
            override fun run() {
                if (!attached) return
                val now = android.os.SystemClock.elapsedRealtime()

                // After a successful render, silence can mean an unchanged
                // remote screen; it is not evidence of a broken transport.
                // Startup/explicit recovery still use the first-frame deadline.
                val hasRendered = renderedFrameSeen.get()
                if (!rawFrameSeen.get() ||
                    (!hasRendered && now - lastRawFrameAtMs > FIRST_FRAME_DEADLINE_MS)
                ) {
                    clearSurfaceFrameRateHintIfNeeded()
                    if (mediaRecoveryAttempts < MAX_MEDIA_RECOVERY_ATTEMPTS) {
                        mediaRecoveryAttempts += 1
                        showVideoStatus("Connected • video stream recovering…")
                        session()?.requestMediaRecovery()
                        mainHandler.postDelayed(this, MEDIA_RECOVERY_RETRY_MS)
                    } else {
                        // The retry budget stops repeated transport repairs, not
                        // observation. A late decoded track must still be able to
                        // advance into the EGL recovery branch.
                        showVideoStatus("Connected • controls work • waiting for live video…")
                        mainHandler.postDelayed(this, RENDER_HEALTH_CHECK_INTERVAL_MS)
                    }
                    return
                }

                // The initial EGL swap is not lifetime proof. Decoding may
                // continue while Surface/EGL presentation stalls much later.
                // Only suspect the renderer when fresh decoded frames keep
                // arriving, the surface is visible, and no swap was observed
                // for a sustained interval. A static/quiet screen and normal
                // packet jitter must not rebuild a healthy decoder.
                val surfaceReady =
                    rendererSurfaceAttached &&
                        surfaceView.holder.surface.isValid &&
                        root.windowVisibility == View.VISIBLE
                val eglStalled = RendererContinuityPolicy.shouldRecover(
                    nowMs = now,
                    lastDecodedAtMs = lastRawFrameAtMs,
                    lastPresentedAtMs = lastPresentedFrameAtMs,
                    hadRendered = renderedFrameSeen.get(),
                    surfaceReady = surfaceReady
                )

                // Do not burn the limited initial-render repair budget while
                // SurfaceView is hidden or its Surface has been destroyed.
                if ((!renderedFrameSeen.get() && surfaceReady) || eglStalled) {
                    if (rendererRecoveryAttempts < MAX_RENDERER_RECOVERY_ATTEMPTS) {
                        rendererRecoveryAttempts += 1
                        showVideoStatus(
                            if (eglStalled) "Live frames arriving • restoring stalled display…"
                            else "Video frames are here • rebuilding display…"
                        )

                        // A second bounded request proves the fresh sample and
                        // EGL rebuild still did not present. Decode counters
                        // must not veto compatibility pixels indefinitely.
                        session()?.requestMediaRecovery()

                        rebuildRenderer()
                        mainHandler.postDelayed(this, RENDER_RECOVERY_RETRY_MS)
                    } else {
                        // Stay alive after exhausting attempts: a later Surface
                        // recreation or successful pending swap may recover
                        // without a new video track or a transport restart.
                        showVideoStatus("Video received • display retrying…")
                        mainHandler.postDelayed(this, RENDER_HEALTH_CHECK_INTERVAL_MS)
                    }
                    return
                }

                // Previously this healthy path never scheduled another check.
                // Monitoring only state timestamps keeps normal video frames
                // entirely on libwebrtc's native codec/render pipeline.
                mainHandler.postDelayed(this, RENDER_HEALTH_CHECK_INTERVAL_MS)
            }
        }

    private val listener =
        object : ControllerWebRtcSession.Listener {
            override fun onLive(geometry: RemoteGeometry) {
                activity.runOnUiThread {
                    if (!attached) return@runOnUiThread
                    this@InlineRemoteControllerView.geometry = geometry
                    adoptLatestFrameForGeometry(geometry)
                    syncControllerOrientation(geometry)
                    updateVideoViewport()
                    showVideoStatus(if (remoteTrack == null) {
                        "Connected • waiting for screen video…"
                    } else {
                        "Video connected • preparing display…"
                    })
                    // HELLO proves controls, not a video track or inbound RTP.
                    // Neither onTrack nor inbound getStats is guaranteed when
                    // the initial video m-section never produces any media.
                    if (!mediaWatchdogArmed) {
                        mediaWatchdogArmed = true
                        mainHandler.postDelayed(mediaWatchdog, FIRST_FRAME_DEADLINE_MS)
                    }
                }
            }

            override fun onConnectivityChanged(
                connected: Boolean
            ) {
                activity.runOnUiThread {
                    if (!connected) {
                        showVideoStatus("Connection interrupted • reconnecting…")
                    } else if (renderedFrameSeen.get()) {
                        status.visibility = View.GONE
                    } else {
                        showVideoStatus("Reconnected • restoring remote screen…")
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
                        lastRawFrameAtMs = 0L
                        lastPresentedFrameAtMs = 0L
                        renderedFrameSeen.set(false)
                        primaryConfirmation.reset()
                        presentationCadence.reset()
                        resetPassiveRenderPriority()
                        lastPresentationHeartbeatAtMs.set(Long.MIN_VALUE / 2)
                        clearSurfaceFrameRateHintIfNeeded()
                        frameWidth = 0
                        frameHeight = 0
                        latestObservedFrameWidth = 0
                        latestObservedFrameHeight = 0
                        mediaRecoveryAttempts = 0
                        rendererRecoveryAttempts = 0
                    }

                    showVideoStatus("Video connected • opening remote screen…")

                    ensureRenderer()
                    attachTrack(track)

                    mainHandler.removeCallbacks(mediaWatchdog)
                    mediaWatchdogArmed = true
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

            override fun onFallbackDeltaFrame(
                frame: FallbackDeltaFrame
            ) {
                decodeFallbackDeltaFrame(frame)
            }

            override fun onPrimaryVideoRecoveryStarted() {
                mainHandler.post {
                    if (attached) {
                        // Serialize epoch changes with the presentation commit.
                        recoveryGeneration.incrementAndGet()
                        lastPresentedFrameAtMs = 0L
                        renderedFrameSeen.set(false)
                        presentationCadence.reset()
                        resetPassiveRenderPriority()
                        lastPresentationHeartbeatAtMs.set(Long.MIN_VALUE / 2)
                        primaryConfirmation.reset()
                        clearSurfaceFrameRateHintIfNeeded()
                        mainHandler.removeCallbacks(mediaWatchdog)
                        mainHandler.postDelayed(mediaWatchdog, MEDIA_RECOVERY_RETRY_MS)
                    }
                }
            }

            override fun onCommandResult(
                sequence: Long,
                applied: Boolean
            ) {
                if (!applied) {
                    activity.runOnUiThread {
                        android.widget.Toast.makeText(activity,
                            "Control command was not applied on the sharing phone.",
                            android.widget.Toast.LENGTH_SHORT).show()
                    }
                }
            }

            override fun onDiagnostic(message: String) {
                if (message.startsWith("video ")) videoStats = message
                if (message.startsWith("Command ACK")) inputStats = message
            }

            override fun onRecoverableError(
                error: Throwable
            ) {
                activity.runOnUiThread {
                    showVideoStatus("Recovering secure connection…")
                }
            }

            override fun onTerminalError(
                error: Throwable
            ) {
                activity.runOnUiThread {
                    showVideoStatus("Session connection ended.")
                }
            }
        }

    fun show() {
        if (attached) return
        attached = true
        if (previousRequestedOrientation == null) {
            previousRequestedOrientation =
                activity.requestedOrientation
        }

        enterControllerImmersiveMode()
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
            scheduleControlHandlePeek()
            ControllerConnectionRuntime.replayUiState(
                sessionId
            )
        }
    }

    fun hide() {
        if (!attached) return
        mainHandler.removeCallbacks(interactionIdle)
        resetPassiveRenderPriority()
        endRemoteMotion()
        attached = false
        mediaWatchdogArmed = false

        mainHandler.removeCallbacks(mediaWatchdog)
        mainHandler.removeCallbacks(controlsAutoHide)
        mainHandler.removeCallbacks(handlePeek)
        ControllerConnectionRuntime.detach(listener)
        detachCurrentTrack()
        releaseRenderer()

        fallbackActive = false
        clearPendingFallbackWork()
        fallbackDecoder.shutdownNow()
        activity.runOnUiThread {
            fallbackImageView.setImageDrawable(null)
            fallbackBitmap?.recycle()
            fallbackBitmap = null
            fallbackScratchBitmap?.recycle()
            fallbackScratchBitmap = null
            fallbackCompositeFrameId = -1L
        }

        remoteTrack = null
        (root.parent as? ViewGroup)?.removeView(root)
        restoreControllerOrientation()
        exitControllerImmersiveMode()
    }

    fun isShowing(): Boolean = attached

    @Suppress("DEPRECATION")
    private fun enterControllerImmersiveMode() {
        if (immersiveModeApplied) return

        val window = activity.window
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.apply {
                hide(WindowInsets.Type.systemBars())
                systemBarsBehavior =
                    WindowInsetsController
                        .BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            val decor = window.decorView
            previousLegacySystemUiVisibility =
                decor.systemUiVisibility
            decor.systemUiVisibility =
                decor.systemUiVisibility or
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
        immersiveModeApplied = true
    }

    @Suppress("DEPRECATION")
    private fun exitControllerImmersiveMode() {
        if (!immersiveModeApplied) return

        val window = activity.window
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.show(
                WindowInsets.Type.systemBars()
            )
        } else {
            previousLegacySystemUiVisibility?.let { previous ->
                window.decorView.systemUiVisibility = previous
            }
            previousLegacySystemUiVisibility = null
        }
        immersiveModeApplied = false
    }

    private fun buildUi() {
        root.setBackgroundColor(Color.BLACK)
        root.keepScreenOn = true

        fallbackImageView.apply {
            setBackgroundColor(Color.BLACK)
            scaleType = ImageView.ScaleType.FIT_CENTER
            visibility = View.GONE
            contentDescription = "Remote screen compatibility video"
        }
        /*
         * Keep the remote video on Android's direct Surface composition path.
         * The Surface stays below the app window so recovery pixels, touch
         * feedback and controls can remain ordinary Views above it.
         */
        surfaceView.setZOrderOnTop(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            surfaceView.setSurfaceLifecycle(
                SurfaceView.SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT
            )
        }
        surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    ensureRenderer()
                    ensureRendererSurface(holder)
                    surfaceFrameRateHints
                        .currentHintFps()
                        .takeIf { it > 0 }
                        ?.let(::applySurfaceFrameRateHint)
                    updateRendererAspect(
                        surfaceView.width,
                        surfaceView.height
                    )
                    remoteTrack?.let(::attachTrack)
                    if (attached && remoteTrack != null) {
                        // A new real Surface is a new rendering opportunity.
                        // Preserve the transport but grant a fresh bounded EGL
                        // repair budget and resume the same watchdog.
                        rendererRecoveryAttempts = 0
                        mainHandler.removeCallbacks(mediaWatchdog)
                        mainHandler.postDelayed(
                            mediaWatchdog,
                            FIRST_FRAME_DEADLINE_MS
                        )
                    }
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int
                ) {
                    ensureRenderer()
                    ensureRendererSurface(holder)
                    updateRendererAspect(width, height)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    releaseRendererSurface()
                }
            }
        )

        rendererContainer.setBackgroundColor(Color.BLACK)
        rendererContainer.addView(touchFeedback, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
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
            surfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        rendererContainer.addView(
            fallbackImageView,
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
        touchFeedback.bringToFront()

        status.apply {
            text = "Connected • waiting for screen video…"
            textSize = 13f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            typeface = Typeface.create(
                "sans-serif-medium",
                Typeface.NORMAL
            )
            background = AarisUi.panel(
                context = activity,
                fill = Color.argb(190, 15, 23, 42),
                radiusDp = 16,
                strokeColor = AarisUi.REMOTE_BORDER
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
                Gravity.CENTER
            ).apply {
                marginStart = dp(12)
                marginEnd = dp(12)
            }
        )

        /*
         * Keep remote-phone bottom controls fully exposed. The old full-width
         * bottom dock could cover exactly the button the controller was trying
         * to press. A compact side rail occupies far less useful screen area and
         * collapses to the pass-through parked handle when not actively used.
         */
        dock.apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            visibility = View.GONE
            setPadding(
                dp(5),
                dp(5),
                dp(5),
                dp(5)
            )
            background = AarisUi.panel(
                context = activity,
                fill = AarisUi.REMOTE_PANEL,
                radiusDp = 20,
                strokeColor = AarisUi.REMOTE_BORDER
            )
            elevation = dp(8).toFloat()
        }

        dock.addOnLayoutChangeListener {
                _,
                left,
                top,
                right,
                bottom,
                oldLeft,
                oldTop,
                oldRight,
                oldBottom ->
            if (
                right - left != oldRight - oldLeft ||
                bottom - top != oldBottom - oldTop
            ) {
                updateRemoteContentSafeArea()
            }
        }

        addButton("Stats") {
            AlertDialog.Builder(activity).setTitle("Connection stats")
                .setMessage("${status.text}\n\n$videoStats\n\n$inputStats\n\nDisplayed frame: ${frameWidth}x${frameHeight}\nRecovery video: $fallbackActive\nCommand ACK measures execution acknowledgement, not pixels reaching the display.")
                .setPositiveButton("OK", null).show()
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
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.END or Gravity.CENTER_VERTICAL
            ).apply {
                marginEnd = dp(10)
            }
        )

        controlHandle.apply {
            text = "⋮"
            textSize = 22f
            isAllCaps = false
            setTextColor(Color.WHITE)
            visibility = View.VISIBLE
            background = AarisUi.panel(
                context = activity,
                fill = AarisUi.REMOTE_PANEL,
                radiusDp = 18,
                strokeColor = AarisUi.REMOTE_BORDER
            )
            elevation = dp(6).toFloat()
            contentDescription =
                "Remote controls. Drag to move when visible. When parked, tap or swipe controls the screen underneath; hold to open controls."
            setOnClickListener {
                AarisUi.haptic(this)
                setControlsVisible(true)
            }
            setOnTouchListener { view, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        mainHandler.removeCallbacks(handlePeek)
                        view.animate().cancel()
                        handleWasParkedOnDown = controlHandleParked
                        if (!handleWasParkedOnDown) {
                            view.alpha = 1f
                            controlHandleParked = false
                        }
                        controlHandleOnRight =
                            view.x + view.width / 2f >=
                                root.width / 2f
                        handleDownRawX = event.rawX
                        handleDownRawY = event.rawY
                        handleStartX = view.x
                        handleStartY = view.y
                        handleDownAt = event.eventTime
                        handleDragging = false
                        true
                    }

                    MotionEvent.ACTION_MOVE -> {
                        val dx = event.rawX - handleDownRawX
                        val dy = event.rawY - handleDownRawY

                        /*
                         * Once parked, the tiny edge strip becomes part of the
                         * remote surface. Do not steal an edge swipe just to
                         * reposition controls. The full 48dp handle can still
                         * be dragged whenever it is visible/unparked.
                         */
                        if (!handleWasParkedOnDown) {
                            if (
                                !handleDragging &&
                                dx * dx + dy * dy >=
                                touchSlop * touchSlop
                            ) {
                                handleDragging = true
                                controlHandleParked = false
                                view.alpha = 1f
                            }

                            if (handleDragging) {
                                val margin =
                                    dp(HANDLE_EDGE_MARGIN_DP).toFloat()
                                val maxX =
                                    (root.width - view.width).toFloat() -
                                        margin
                                val maxY =
                                    (root.height - view.height).toFloat() -
                                        margin

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
                        }
                        true
                    }

                    MotionEvent.ACTION_UP -> {
                        if (handleWasParkedOnDown) {
                            val heldFor =
                                event.eventTime - handleDownAt
                            val dx =
                                event.rawX - handleDownRawX
                            val dy =
                                event.rawY - handleDownRawY
                            val moved =
                                dx * dx + dy * dy >=
                                    touchSlop * touchSlop

                            when {
                                !moved &&
                                    heldFor >=
                                        ViewConfiguration
                                            .getLongPressTimeout() -> {
                                    controlHandleParked = false
                                    AarisUi.haptic(view)
                                    setControlsVisible(true)
                                }

                                moved -> {
                                    forwardParkedHandleSwipe(
                                        fromRawX = handleDownRawX,
                                        fromRawY = handleDownRawY,
                                        toRawX = event.rawX,
                                        toRawY = event.rawY,
                                        durationMs = heldFor.toInt()
                                    )
                                    controlHandleParked = true
                                    applyParkedHandlePosition()
                                    scheduleControlHandlePeek()
                                }

                                else -> {
                                    forwardParkedHandleTap(
                                        event.rawX,
                                        event.rawY
                                    )
                                    controlHandleParked = true
                                    applyParkedHandlePosition()
                                    scheduleControlHandlePeek()
                                }
                            }
                        } else if (handleDragging) {
                            controlHandleUserMoved = true
                            snapControlHandleToNearestEdge()
                        } else {
                            view.performClick()
                        }
                        handleWasParkedOnDown = false
                        true
                    }

                    MotionEvent.ACTION_CANCEL -> {
                        handleDragging = false
                        handleWasParkedOnDown = false
                        if (controlHandleParked) {
                            applyParkedHandlePosition()
                        }
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

    private fun forwardParkedHandleTap(
        rawX: Float,
        rawY: Float
    ) {
        val currentGeometry = geometry ?: return
        val currentSession = session() ?: return
        if (
            !rawX.isFinite() ||
            !rawY.isFinite()
        ) {
            return
        }

        val location = IntArray(2)
        rendererContainer.getLocationOnScreen(location)
        val point =
            normalize(
                x = rawX - location[0],
                y = rawY - location[1],
                geometry = currentGeometry,
                clampToContent = false
            ) ?: return

        beginRemoteMotion()
        currentSession.sendTap(
            point.x,
            point.y,
            currentGeometry.generation
        )
        scheduleRemoteMotionIdle()
    }

    private fun forwardParkedHandleSwipe(
        fromRawX: Float,
        fromRawY: Float,
        toRawX: Float,
        toRawY: Float,
        durationMs: Int
    ) {
        val currentGeometry = geometry ?: return
        val currentSession = session() ?: return
        if (
            !fromRawX.isFinite() ||
            !fromRawY.isFinite() ||
            !toRawX.isFinite() ||
            !toRawY.isFinite()
        ) {
            return
        }

        val location = IntArray(2)
        rendererContainer.getLocationOnScreen(location)
        val start =
            normalize(
                x = fromRawX - location[0],
                y = fromRawY - location[1],
                geometry = currentGeometry,
                clampToContent = false
            ) ?: return
        val end =
            normalize(
                x = toRawX - location[0],
                y = toRawY - location[1],
                geometry = currentGeometry,
                clampToContent = true
            ) ?: return

        beginRemoteMotion()
        currentSession.sendSwipe(
            fromNx = start.x,
            fromNy = start.y,
            toNx = end.x,
            toNy = end.y,
            durationMs =
                latencyOptimizedGestureDuration(
                    durationMs.coerceAtLeast(
                        MIN_REMOTE_GESTURE_MS
                    )
                ),
            expectedGeneration = currentGeometry.generation
        )
        scheduleRemoteMotionIdle()
    }

    private fun setControlsVisible(visible: Boolean) {
        mainHandler.removeCallbacks(controlsAutoHide)
        mainHandler.removeCallbacks(handlePeek)

        if (visible) {
            positionDockForHandleSide()
        }
        dock.visibility =
            if (visible) View.VISIBLE else View.GONE
        controlHandle.visibility =
            if (visible) View.GONE else View.VISIBLE
        updateRemoteContentSafeArea()
        if (visible) {
            dock.post {
                if (attached && dock.visibility == View.VISIBLE) {
                    updateRemoteContentSafeArea()
                }
            }
        }

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

    private fun positionDockForHandleSide() {
        val params =
            dock.layoutParams as? FrameLayout.LayoutParams ?: return
        val targetGravity =
            (if (controlHandleOnRight) Gravity.END else Gravity.START) or
                Gravity.CENTER_VERTICAL
        val targetStartMargin =
            if (controlHandleOnRight) 0 else dp(10)
        val targetEndMargin =
            if (controlHandleOnRight) dp(10) else 0

        if (
            params.gravity == targetGravity &&
            params.marginStart == targetStartMargin &&
            params.marginEnd == targetEndMargin
        ) {
            return
        }

        params.gravity = targetGravity
        params.marginStart = targetStartMargin
        params.marginEnd = targetEndMargin
        dock.layoutParams = params
        updateRemoteContentSafeArea()
    }

    private fun updateRemoteContentSafeArea() {
        val params =
            rendererContainer.layoutParams as? FrameLayout.LayoutParams
                ?: return
        val insets =
            RemoteControllerLayoutPolicy.contentInsets(
                dockVisible = dock.visibility == View.VISIBLE,
                dockOnRight = controlHandleOnRight,
                dockWidthPx = dock.width,
                gapPx = dp(20)
            )
        if (
            params.leftMargin == insets.leftPx &&
            params.rightMargin == insets.rightPx
        ) {
            return
        }

        params.leftMargin = insets.leftPx
        params.rightMargin = insets.rightPx
        rendererContainer.layoutParams = params
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
            controlHandle.x + controlHandle.width / 2f
        controlHandleOnRight = center >= root.width / 2f
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

        val targetX = parkedHandleX()

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
            /*
             * Keep the remote-control glass path independent from the Android
             * main looper. SurfaceView/SurfaceFlinger already owns physical
             * display composition; adding WebRTC's Choreographer-backed
             * RenderSynchronizer makes every swap depend on main-thread frame
             * callbacks as well. Touch dispatch, layout or UI animation can then
             * delay the render window even while decode and the EGL thread are
             * healthy, turning ordinary UI jank into visible remote-video
             * judder.
             *
             * Use WebRTC's normal SurfaceView-style EGL thread instead. The
             * EglRenderer still keeps a one-frame latest-wins pending slot,
             * presentation timestamps remain disabled, and Surface.setFrameRate
             * keeps the existing best-effort display-mode hint. No extra frame
             * queue or media clock is introduced.
             */
            val renderThread =
                EglThread.create(
                    null,
                    WebRtcRuntime.eglBase(activity)
                        .eglBaseContext,
                    EglBase.CONFIG_PLAIN
                )
            renderEglThread = renderThread
            applyRenderThreadPriority(renderThread)
            /*
             * Remote-control rendering remains freshness-first, not
             * presentation-timestamp/A/V-sync-first. Keep presentation
             * timestamps disabled and overwritePendingFrames enabled so decoded
             * frame admission is latest-wins rather than FIFO.
             */
            renderer.init(
                renderThread,
                GlRectDrawer(),
                false,
                true
            )
            renderer.setMirror(false)
            renderer.disableFpsReduction()
            updateRendererAspect(
                surfaceView.width,
                surfaceView.height,
                renderer
            )
            // FrameListener is a ONE-SHOT screenshot API. RenderListener fires
            // after every real EGL swap, so recovery can be confirmed repeatedly.
            installPresentationListener(renderer)

            eglRenderer = renderer
            ensureRendererSurface()
            true
        }.getOrDefault(false)
    }

    private fun installPresentationListener(renderer: EglRenderer) {
        renderer.addRenderListener {
            // Capture the epoch before checking the Surface. Surface loss
            // disables observation, fences the EGL thread, then advances this
            // epoch, so an old swap cannot adopt a new Surface's identity.
            val generation = recoveryGeneration.get()
            if (
                eglRenderer !== renderer ||
                !rendererSurfaceAttached
            ) return@addRenderListener
            val presentedAtMs =
                android.os.SystemClock.elapsedRealtime()
            lastPresentedFrameAtMs = presentedAtMs

            /*
             * One synchronized O(1) check per actual EGL swap. It emits no
             * packet unless an authoritative applied-input probe is pending,
             * so this adds no steady-state telemetry loop or media queue.
             */
            session()?.onFramePresented(presentedAtMs)

            /*
             * Cadence windows need multiple swaps and can be reset during
             * recovery. A tiny proof-of-glass heartbeat is independent:
             * one real EGL swap is enough to prove that pixels reached the
             * controller display. Throttle it so it never competes with
             * authoritative touch traffic.
             */
            val previousHeartbeat =
                lastPresentationHeartbeatAtMs.get()
            if (
                presentedAtMs - previousHeartbeat >=
                    PRESENTATION_HEARTBEAT_INTERVAL_MS &&
                lastPresentationHeartbeatAtMs.compareAndSet(
                    previousHeartbeat,
                    presentedAtMs
                )
            ) {
                mainHandler.post {
                    if (
                        attached &&
                        eglRenderer === renderer &&
                        rendererSurfaceAttached &&
                        generation == recoveryGeneration.get() &&
                        RendererContinuityPolicy.isFreshPresentationCallback(
                            nowMs = android.os.SystemClock.elapsedRealtime(),
                            presentedAtMs = presentedAtMs
                        )
                    ) {
                        session()?.sendPresentationHeartbeat()
                    }
                }
            }

            presentationCadence
                .onPresented(presentedAtMs, decodedFrameSequence.get())
                ?.let { window ->
                    mainHandler.post {
                        if (
                            attached &&
                            eglRenderer === renderer &&
                            rendererSurfaceAttached &&
                            generation == recoveryGeneration.get() &&
                            RendererContinuityPolicy.isFreshPresentationCallback(
                                nowMs = android.os.SystemClock.elapsedRealtime(),
                                presentedAtMs = presentedAtMs
                            )
                        ) {
                            /*
                             * Keep the render scheduler hot for actual
                             * post-touch motion. Host capture has a matching
                             * natural-motion tail, so dropping EGL back to
                             * default priority at finger-up can otherwise
                             * turn a healthy 45/60 fps fling into controller-
                             * side micro-stutter.
                             */
                            passiveRenderMotion.observe(
                                window = null,
                                nowMs = presentedAtMs,
                                sourceFps = window.fps
                            )
                            val passiveRenderActive =
                                passiveRenderMotion.isActive(presentedAtMs)
                            setRenderPassivePriority(passiveRenderActive)
                            mainHandler.removeCallbacks(
                                passiveRenderPriorityExpiry
                            )
                            if (passiveRenderActive) {
                                mainHandler.postDelayed(
                                    passiveRenderPriorityExpiry,
                                    PASSIVE_RENDER_PRIORITY_TAIL_MS + 1L
                                )
                            }

                            /*
                             * Presentation feedback remains health evidence
                             * for host adaptation. The Surface hint itself is
                             * stream-stable: observe() may bootstrap one vote
                             * for passive viewing, but can never chase the
                             * variable delivered cadence afterward.
                             */
                            surfaceFrameRateHints
                                .observe(window, presentedAtMs)
                                ?.let(::applySurfaceFrameRateHint)
                            // Display capability is published by
                            // ControllerWebRtcSession independently of EGL
                            // cadence. This window reports only proof-of-glass.
                            session()?.sendPresentationFeedback(window)
                            if (renderedFrameSeen.get()) {
                                primaryConfirmation.onPresented(presentedAtMs) {
                                    session()?.confirmPrimaryVideoRendered() == true
                                }
                            }
                        }
                    }
                }
            if (eglRenderer === renderer && !renderedFrameSeen.get() &&
                renderConfirmationGeneration.compareAndSet(-1L, generation)) {
                activity.runOnUiThread {
                    try {
                        if (
                            attached &&
                            eglRenderer === renderer &&
                            rendererSurfaceAttached &&
                            generation == recoveryGeneration.get() &&
                            RendererContinuityPolicy.isFreshPresentationCallback(
                                nowMs = android.os.SystemClock.elapsedRealtime(),
                                presentedAtMs = presentedAtMs
                            )
                        ) {
                            // Commit health only after checking the generation on
                            // the UI thread. An old queued swap must not latch true
                            // and hide every fresh confirmation after recovery.
                            renderedFrameSeen.set(true)
                            clearPendingFallbackWork()
                            fallbackActive = false
                            imageDisplayed = true
                            fallbackImageView.visibility = View.GONE
                            fallbackImageView.setImageDrawable(null)
                            fallbackBitmap?.recycle()
                            fallbackBitmap = null
                            fallbackScratchBitmap?.recycle()
                            fallbackScratchBitmap = null
                            fallbackCompositeFrameId = -1L
                            showVideoStatus("Live video connected")
                            primaryConfirmation.onPresented(presentedAtMs) {
                                session()?.confirmPrimaryVideoRendered() == true
                            }
                            mediaRecoveryAttempts = 0
                            rendererRecoveryAttempts = 0
                            setControlsVisible(false)
                        }
                    } finally {
                        renderConfirmationGeneration.compareAndSet(generation, -1L)
                    }
                }
            }
        }
    }

    private fun rebuildRenderer() {
        detachCurrentTrack()
        releaseRenderer()

        rendererContainer.postDelayed(
            {
                if (!attached) return@postDelayed
                ensureRenderer()
                remoteTrack?.let(::attachTrack)
            },
            250L
        )
    }

    private fun ensureRendererSurface(
        holder: SurfaceHolder = surfaceView.holder
    ): Boolean {
        val renderer = eglRenderer ?: return false
        if (rendererSurfaceAttached) return true

        val surface = holder.surface
        if (!surface.isValid) return false

        return runCatching {
            renderer.createEglSurface(surface)
            rendererSurfaceAttached = true
            true
        }.getOrElse {
            rendererSurfaceAttached = false
            false
        }
    }

    private fun clearSurfaceFrameRateHintIfNeeded() {
        if (surfaceFrameRateHints.reset()) {
            // Android defines 0 Hz as clearing this Surface's preference.
            applySurfaceFrameRateHint(0)
        }
    }

    /**
     * Display-scheduler hint only: WebRTC still owns production, congestion
     * control and pacing. Android may ignore the request. DEFAULT compatibility
     * fits mixed remote UI/video, and Android 12+ may switch only seamlessly.
     */
    private fun applySurfaceFrameRateHint(fps: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || fps < 0) return

        val surface = surfaceView.holder.surface
        if (!surface.isValid) return

        runCatching {
            /*
             * This stream is variable-rate remote UI/video, not a request for
             * "any display clock >= 60". On a 90 Hz panel, Android 16's AT_LEAST
             * contract may legally keep/select 90 Hz for a 60 fps stream, which
             * creates a deterministic 2:3 presentation cadence. DEFAULT keeps
             * 60 as a preference while still letting SurfaceFlinger choose a
             * compatible mode such as 60/120 and while allowing the system to
             * ignore the hint when necessary.
             *
             * Keep the request stable for the whole stream and only permit
             * seamless mode changes. Network-driven FPS changes must never
             * toggle physical display modes.
             */
            val compatibility =
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                surface.setFrameRate(
                    fps.toFloat(),
                    compatibility,
                    Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS
                )
            } else {
                @Suppress("DEPRECATION")
                surface.setFrameRate(
                    fps.toFloat(),
                    compatibility
                )
            }
        }
    }

    private fun releaseRendererSurface() {
        val renderer = eglRenderer
        rendererSurfaceAttached = false
        if (renderer != null) {
            // SurfaceHolder requires rendering to stop before surfaceDestroyed
            // returns. Match the pinned WebRTC SurfaceEglRenderer contract:
            // releaseEglSurface only posts work; its callback is the EGL fence.
            // The callback must never depend on the UI thread waiting here.
            val released = CountDownLatch(1)
            renderer.releaseEglSurface(released::countDown)
            ThreadUtils.awaitUninterruptibly(released)
        }
        resetPresentationAfterEglFence()
    }

    private fun releaseRenderer() {
        val renderer = eglRenderer
        eglRenderer = null
        renderEglThread = null
        rendererSurfaceAttached = false
        // EglRenderer.release() already waits for its EGL cleanup barrier.
        runCatching { renderer?.release() }
        resetPresentationAfterEglFence()
    }

    private fun resetPresentationAfterEglFence() {
        // Advance only after old render callbacks have finished. Otherwise an
        // in-flight old swap could read the new epoch and confirm a new Surface.
        recoveryGeneration.incrementAndGet()
        lastPresentedFrameAtMs = 0L
        renderedFrameSeen.set(false)
        renderConfirmationGeneration.set(-1L)
        primaryConfirmation.reset()
        presentationCadence.reset()
        lastPresentationHeartbeatAtMs.set(Long.MIN_VALUE / 2)
        resetPassiveRenderPriority()
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

    private fun adoptLatestFrameForGeometry(
        remote: RemoteGeometry
    ) {
        val observedWidth = latestObservedFrameWidth
        val observedHeight = latestObservedFrameHeight
        if (
            observedWidth > 0 &&
            observedHeight > 0 &&
            RemoteViewportMapper.frameMatchesRemote(
                remoteWidth = remote.widthPx,
                remoteHeight = remote.heightPx,
                frameWidth = observedWidth,
                frameHeight = observedHeight
            )
        ) {
            frameWidth = observedWidth
            frameHeight = observedHeight
        } else if (
            frameWidth > 0 &&
            frameHeight > 0 &&
            !RemoteViewportMapper.frameMatchesRemote(
                remoteWidth = remote.widthPx,
                remoteHeight = remote.heightPx,
                frameWidth = frameWidth,
                frameHeight = frameHeight
            )
        ) {
            // Do not let the previous portrait/landscape frame pin the new
            // generation to a stale viewport while the first matching frame
            // is still crossing WebRTC.
            frameWidth = 0
            frameHeight = 0
        }
    }

    private fun syncControllerOrientation(
        remote: RemoteGeometry
    ) {
        val target =
            when (
                RemoteControllerLayoutPolicy.orientation(
                    remote.widthPx,
                    remote.heightPx
                )
            ) {
                RemoteScreenOrientation.LANDSCAPE ->
                    ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                RemoteScreenOrientation.PORTRAIT ->
                    ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
                null -> return
            }

        if (activity.requestedOrientation != target) {
            activity.requestedOrientation = target
        }
    }

    private fun restoreControllerOrientation() {
        val previous = previousRequestedOrientation ?: return
        previousRequestedOrientation = null
        if (activity.requestedOrientation != previous) {
            activity.requestedOrientation = previous
        }
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
            (surfaceView.layoutParams as? FrameLayout.LayoutParams)
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
            surfaceView.layoutParams = params
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
        synchronized(fallbackAdmissionLock) {
            if (!attached || renderedFrameSeen.get() ||
                frame.frameId < lastFallbackFrameId.get()
            ) return
            val previous = pendingFallbackFrame.getAndSet(
                frame.copy(jpeg = frame.jpeg.copyOf())
            )
            if (previous != null) {
                // A newer full anchor supersedes the replaced anchor's chain.
                // Its complete pixels provide the new dependency checkpoint.
                discardDeferredFallbackDeltas(previous.frameId)
            }
        }
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
        var uiCommitPending = false
        var anchorFrameId = -1L
        try {
            if (!attached || renderedFrameSeen.get()) return
            val frame = synchronized(fallbackAdmissionLock) {
                pendingFallbackFrame.getAndSet(null)?.also {
                    activeFallbackAnchorId = it.frameId
                }
            } ?: return
            anchorFrameId = frame.frameId
            // Decode one anchor per executor turn. The permit stays held until
            // its UI commit finishes, bounding decoded pixels as well as JPEGs.
            // A new executor turn also gives queued dependent deltas a chance
            // to run; a continuous anchor drain must not starve them.
            uiCommitPending = decodeFallbackFrameNow(frame)
        } finally {
            if (!uiCommitPending) completeFallbackDecode(anchorFrameId)
        }
    }

    private fun completeFallbackDecode(anchorFrameId: Long, committed: Boolean = false) {
        var dependencyLost = false
        synchronized(fallbackAdmissionLock) {
            val ready = deferredFallbackDeltas.filter { it.anchorFrameId == anchorFrameId }
            deferredFallbackDeltas.removeAll { it.anchorFrameId == anchorFrameId }
            if (activeFallbackAnchorId == anchorFrameId) activeFallbackAnchorId = -1L
            if (committed && attached && !renderedFrameSeen.get()) {
                // Submit before releasing admission: a newer dependent delta
                // must not overtake the chain that was waiting for this anchor.
                ready.forEach { submitFallbackDelta(it.frame) }
            } else {
                deltaFramesInFlight.addAndGet(-ready.size)
                dependencyLost = ready.isNotEmpty()
            }
        }
        fallbackDecodeScheduled.set(false)
        if (!attached || renderedFrameSeen.get()) {
            clearPendingFallbackWork()
            return
        }
        if (dependencyLost) requestRecoveryAnchor()
        if (pendingFallbackFrame.get() != null) {
            scheduleFallbackDecode()
        }
    }

    private fun discardDeferredFallbackDeltas(anchorFrameId: Long) {
        val before = deferredFallbackDeltas.size
        deferredFallbackDeltas.removeAll { it.anchorFrameId == anchorFrameId }
        deltaFramesInFlight.addAndGet(deferredFallbackDeltas.size - before)
    }

    private fun clearPendingFallbackWork() {
        synchronized(fallbackAdmissionLock) {
            pendingFallbackFrame.set(null)
            deltaFramesInFlight.addAndGet(-deferredFallbackDeltas.size)
            deferredFallbackDeltas.clear()
        }
    }

    private fun decodeFallbackFrameNow(
        frame: FallbackVideoFrame
    ): Boolean {
        val oriented = RecoveryBitmapRenderer.decode(
            frame.jpeg, frame.width, frame.height, frame.rotation
        ) ?: run { requestRecoveryAnchor(); return false }

        /*
         * If a newer fallback frame arrived while this JPEG was decoding,
         * skip presenting the stale bitmap. The next executor turn decodes
         * the newest frame directly.
         */
        if (
            frame.frameId < lastFallbackFrameId.get() &&
            pendingFallbackFrame.get() != null
        ) {
            oriented.recycle()
            return false
        }

        return postDecodedFallbackFrame(frame, oriented)
    }

    private fun postDecodedFallbackFrame(
        frame: FallbackVideoFrame,
        oriented: Bitmap
    ): Boolean {
        var posted = false
        try {
            // Each anchor owns its callback. Replacing a bitmap behind an old
            // callback could commit a newer anchor ahead of earlier delta work.
            posted = mainHandler.post {
                try {
                    presentFallbackFrame(frame, oriented)
                } finally {
                    if (fallbackBitmap !== oriented && !oriented.isRecycled) {
                        oriented.recycle()
                    }
                    completeFallbackDecode(
                        frame.frameId,
                        committed = fallbackBitmap === oriented &&
                            fallbackCompositeFrameId == frame.frameId
                    )
                }
            }
            return posted
        } finally {
            // Until post succeeds, the worker still owns the decoded bitmap.
            if (!posted && !oriented.isRecycled) oriented.recycle()
        }
    }

    private fun presentFallbackFrame(
        frame: FallbackVideoFrame,
        oriented: Bitmap
    ) {
        if (
            !attached ||
            renderedFrameSeen.get()
        ) {
            return
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
            return
        }

        if (frame.frameId <= fallbackCompositeFrameId) {
            return
        }

        fallbackActive = true
        imageDisplayed = true
        fallbackCompositeFrameId = frame.frameId
        frameWidth = oriented.width
        frameHeight = oriented.height
        updateVideoViewport()

        val previous = fallbackBitmap
        val previousScratch = fallbackScratchBitmap
        fallbackBitmap = oriented
        fallbackScratchBitmap = null
        fallbackImageView.setImageBitmap(oriented)
        fallbackImageView.visibility = View.VISIBLE

        if (
            previous != null &&
            previous !== oriented &&
            !previous.isRecycled
        ) {
            previous.recycle()
        }
        if (
            previousScratch != null &&
            previousScratch !== oriented &&
            previousScratch !== previous &&
            !previousScratch.isRecycled
        ) {
            previousScratch.recycle()
        }

        showVideoStatus("Compatibility video active • primary stream recovering…")
    }

    // Recovery details remain in Stats. Never cover usable remote pixels with
    // progress text; a centered placeholder is only needed before any image.
    private fun showVideoStatus(message: String) {
        status.text = message
        status.visibility = if (imageDisplayed) View.GONE else View.VISIBLE
    }

    private fun requestRecoveryAnchor() {
        mainHandler.post {
            val now = android.os.SystemClock.elapsedRealtime()
            if (attached && !renderedFrameSeen.get() && now - lastAnchorRequestMs >= 1000L) {
                lastAnchorRequestMs = now
                session()?.requestMediaRecovery()
            }
        }
    }

    private fun decodeFallbackDeltaFrame(frame: FallbackDeltaFrame) {
        if (!attached || renderedFrameSeen.get()) return
        // Bound decoding AND already-posted UI work. Dropping a dependent delta
        // requires a full anchor, rather than applying it over the wrong base.
        if (deltaFramesInFlight.incrementAndGet() > 3) {
            deltaFramesInFlight.decrementAndGet()
            requestRecoveryAnchor()
            return
        }
        synchronized(fallbackAdmissionLock) {
            if (!attached || renderedFrameSeen.get()) {
                deltaFramesInFlight.decrementAndGet()
                return
            }
            val anchorId = when (frame.baseFrameId) {
                activeFallbackAnchorId -> activeFallbackAnchorId.takeIf { it >= 0L }
                pendingFallbackFrame.get()?.frameId -> frame.baseFrameId
                else -> deferredFallbackDeltas
                    .firstOrNull { it.frame.frameId == frame.baseFrameId }
                    ?.anchorFrameId
            }
            if (anchorId != null) {
                // These compressed packets share the existing three-delta
                // budget. Their decoder tasks are admitted only after the full
                // dependency's UI commit, never in front of its pixels.
                deferredFallbackDeltas.addLast(DeferredFallbackDelta(anchorId, frame))
            } else {
                submitFallbackDelta(frame)
            }
        }
    }

    private fun submitFallbackDelta(frame: FallbackDeltaFrame) {
        try {
            fallbackDecoder.execute { decodeFallbackDeltaFrameNow(frame) }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            deltaFramesInFlight.decrementAndGet()
        }
    }

    private fun decodeFallbackDeltaFrameNow(frame: FallbackDeltaFrame) {
        val decoded = ArrayList<DecodedDeltaPatch>(frame.patches.size)
        var posted = false
        try {
            if (!attached || renderedFrameSeen.get()) return
            if (frame.patches.sumOf { it.width.toLong() * it.height } > frame.width.toLong() * frame.height) {
                requestRecoveryAnchor(); return
            }
            for (patch in frame.patches) {
                val item = decodeOrientedDeltaPatch(frame, patch)
                if (item == null) { requestRecoveryAnchor(); return }
                decoded += item
            }
            // Check baseFrameId on the UI thread, after earlier UI commits.
            // Checking it while decoding could discard a valid next delta while
            // its predecessor was still waiting to be presented.
            posted = mainHandler.post {
                try { applyFallbackDeltaFrame(frame, decoded) }
                finally {
                    decoded.forEach { if (!it.bitmap.isRecycled) it.bitmap.recycle() }
                    deltaFramesInFlight.decrementAndGet()
                }
            }
        } finally {
            if (!posted) {
                decoded.forEach { if (!it.bitmap.isRecycled) it.bitmap.recycle() }
                deltaFramesInFlight.decrementAndGet()
            }
        }
    }

    private fun applyFallbackDeltaFrame(frame: FallbackDeltaFrame, decoded: List<DecodedDeltaPatch>) {
        if (
            !attached ||
            renderedFrameSeen.get() ||
            frame.baseFrameId != fallbackCompositeFrameId
        ) {
            if (frame.frameId > fallbackCompositeFrameId) requestRecoveryAnchor()
            return
        }

        val current = fallbackBitmap
        if (current == null || current.isRecycled) {
            requestRecoveryAnchor()
            return
        }

        val orientedWidth =
            if (frame.rotation == 90 || frame.rotation == 270) {
                frame.height
            } else {
                frame.width
            }
        val orientedHeight =
            if (frame.rotation == 90 || frame.rotation == 270) {
                frame.width
            } else {
                frame.height
            }
        val currentGeometry = geometry
        if (
            current.width != orientedWidth ||
            current.height != orientedHeight ||
            (
                currentGeometry != null &&
                !RemoteViewportMapper.frameMatchesRemote(
                    remoteWidth = currentGeometry.widthPx,
                    remoteHeight = currentGeometry.heightPx,
                    frameWidth = orientedWidth,
                    frameHeight = orientedHeight
                )
            )
        ) {
            requestRecoveryAnchor()
            return
        }

        var scratch = fallbackScratchBitmap
        if (
            scratch == null ||
            scratch.isRecycled ||
            !scratch.isMutable ||
            scratch.width != orientedWidth ||
            scratch.height != orientedHeight
        ) {
            scratch?.takeIf { !it.isRecycled && it !== current }?.recycle()
            scratch = Bitmap.createBitmap(
                orientedWidth,
                orientedHeight,
                Bitmap.Config.ARGB_8888
            )
        }

        scratch.density = Bitmap.DENSITY_NONE
        scratch.eraseColor(Color.BLACK)
        val canvas = Canvas(scratch)
        val (shiftX, shiftY) = orientedShift(
            frame.shiftX,
            frame.shiftY,
            frame.rotation
        )
        RecoveryBitmapRenderer.drawPixels(canvas, current, shiftX, shiftY)
        decoded.forEach { patch ->
            RecoveryBitmapRenderer.drawPixels(canvas, patch.bitmap, patch.x, patch.y)
        }

        fallbackImageView.setImageBitmap(scratch)
        fallbackBitmap = scratch
        fallbackScratchBitmap =
            if (current.isMutable && !current.isRecycled) {
                current
            } else {
                if (!current.isRecycled) current.recycle()
                null
            }
        fallbackCompositeFrameId = frame.frameId
        fallbackActive = true
        imageDisplayed = true
        latestObservedFrameWidth = orientedWidth
        latestObservedFrameHeight = orientedHeight
        frameWidth = orientedWidth
        frameHeight = orientedHeight
        updateVideoViewport()
        fallbackImageView.visibility = View.VISIBLE
        showVideoStatus("Adaptive recovery video • primary stream recovering…")

    }

    private fun decodeOrientedDeltaPatch(
        frame: FallbackDeltaFrame,
        patch: FallbackDeltaPatch
    ): DecodedDeltaPatch? {
        val oriented = RecoveryBitmapRenderer.decode(
            patch.jpeg, patch.width, patch.height, frame.rotation
        ) ?: return null

        val coordinates = when (frame.rotation) {
            90 ->
                (frame.height - patch.y - patch.height) to patch.x
            180 ->
                (frame.width - patch.x - patch.width) to
                    (frame.height - patch.y - patch.height)
            270 ->
                patch.y to
                    (frame.width - patch.x - patch.width)
            else -> patch.x to patch.y
        }

        return DecodedDeltaPatch(
            x = coordinates.first,
            y = coordinates.second,
            bitmap = oriented
        )
    }

    private fun orientedShift(
        shiftX: Int,
        shiftY: Int,
        rotation: Int
    ): Pair<Int, Int> = when (rotation) {
        90 -> -shiftY to shiftX
        180 -> -shiftX to -shiftY
        270 -> shiftY to -shiftX
        else -> shiftX to shiftY
    }

    private fun addButton(
        label: String,
        autoHide: Boolean = false,
        action: () -> Unit
    ) {
        dock.addView(
            Button(activity).apply {
                text = label
                AarisUi.remoteDockButton(
                    this,
                    danger = label == "End"
                )
                contentDescription =
                    when (label) {
                        "Apps" -> "Remote recent apps"
                        "End" -> "End remote session"
                        else -> "Remote $label"
                    }
                setOnClickListener {
                    AarisUi.haptic(this)
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
                dp(68),
                dp(44)
            ).apply {
                topMargin = dp(2)
                bottomMargin = dp(2)
            }
        )
    }

    private fun handleTouch(event: MotionEvent): Boolean {
        val g = geometry ?: return true
        val s = session() ?: return true
        touchFeedback.track(event)

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
                    firstPointerId = event.getPointerId(firstIndex)
                    secondPointerId = event.getPointerId(secondIndex)
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
                        sendMultiTouchGesture(s, g, event.eventTime)
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
                        sendMultiTouchGesture(s, g, event.eventTime)
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
                        upY = event.y,
                        upEventTimeMs = event.eventTime
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
                endRemoteMotion()
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
                    expectedGeneration = geometry.generation
                )

            if (sent) {
                liveGestureStreamId = streamId
                liveGestureStreamActive = true
                liveGestureLastEventTime = event.eventTime
                gestureStreamPacer.onSent(event.eventTime)
            }
            return
        }

        if (!gestureStreamPacer.shouldAttempt(event.eventTime)) {
            return
        }

        val elapsed =
            event.eventTime - liveGestureLastEventTime

        /*
         * Preserve the shape of fast curved drags while pacing the transport
         * independently from the video frame cadence. Healthy control traffic can
         * run at a 60 Hz-class cadence; DataChannel backpressure immediately
         * stretches that cadence and the host independently coalesces queued
         * CONTINUE segments, preventing old pointer positions from accumulating.
         */
        val points =
            liveGesturePointsSince(
                geometry = geometry,
                afterMs = liveGestureLastEventTime,
                fallbackX = event.x,
                fallbackY = event.y
            )
        if (points.isEmpty()) return

        val sent =
            session.sendGestureStreamSegment(
                streamId = liveGestureStreamId,
                phase = GestureStreamPhase.CONTINUE,
                points = points,
                durationMs = streamSegmentDuration(elapsed),
                expectedGeneration = geometry.generation
            )
        if (sent) {
            liveGestureLastEventTime = event.eventTime
            gestureStreamPacer.onSent(event.eventTime)
        } else {
            gestureStreamPacer.onBackpressure(event.eventTime)
        }
    }

    private fun liveGesturePointsSince(
        geometry: RemoteGeometry,
        afterMs: Long,
        fallbackX: Float,
        fallbackY: Float
    ): List<Pair<Float, Float>> {
        var firstRecent = gesturePoints.size
        for (index in gesturePoints.indices) {
            if (gesturePoints[index].atMs > afterMs) {
                firstRecent = index
                break
            }
        }

        val startIndex =
            maxOf(
                firstRecent,
                gesturePoints.size - MAX_LIVE_STREAM_POINTS
            )
        val result =
            ArrayList<Pair<Float, Float>>(
                minOf(
                    MAX_LIVE_STREAM_POINTS,
                    (gesturePoints.size - startIndex)
                        .coerceAtLeast(0)
                ).coerceAtLeast(1)
            )

        for (index in startIndex until gesturePoints.size) {
            val local = gesturePoints[index]
            val normalized =
                normalize(
                    x = local.x,
                    y = local.y,
                    geometry = geometry,
                    clampToContent = true
                ) ?: continue
            val point = normalized.x to normalized.y
            if (result.lastOrNull() != point) {
                result += point
            }
        }

        if (result.isEmpty()) {
            normalize(
                x = fallbackX,
                y = fallbackY,
                geometry = geometry,
                clampToContent = true
            )?.let { normalized ->
                result += normalized.x to normalized.y
            }
        }

        return result
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
                        eventTime - liveGestureLastEventTime
                    ),
                expectedGeneration = geometry.generation
            )
        }

        resetLiveGestureStream()
    }

    private fun resetLiveGestureStream() {
        liveGestureStreamId = 0L
        liveGestureStreamActive = false
        liveGestureLastEventTime = 0L
        gestureStreamPacer.reset()
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
        setRenderInteractionPriority(true)

        /*
         * Bootstrap one stable display-capacity vote immediately. Do not retune
         * SurfaceFlinger to later 45/48/50/55-fps delivery windows: this
         * controller uses render-ASAP/latest-frame-wins semantics, so the
         * variable media cadence stays health evidence rather than becoming a
         * second display-pacing actuator.
         */
        surfaceFrameRateHints
            .beginInteraction()
            ?.let(::applySurfaceFrameRateHint)

        session()?.setInteractionActive(true)
    }

    private fun endRemoteMotion() {
        setRenderInteractionPriority(false)

        session()?.setInteractionActive(false)
    }

    /**
     * The EglRenderer already keeps a one-frame queue and overwrites stale
     * pending renders. Give that tiny render lane a scheduling advantage while
     * either remote input is active or real EGL cadence proves continuing
     * post-touch motion, so swapBuffers is less likely to miss a display
     * opportunity because unrelated app work happened first.
     *
     * Priority changes do not increase requested FPS or create additional GPU
     * work. Quiet presentation naturally releases the passive-motion tail.
     */
    private fun setRenderInteractionPriority(active: Boolean) {
        if (renderTouchPriorityActive == active) return
        renderTouchPriorityActive = active
        updateRenderPriority()
    }

    private fun setRenderPassivePriority(active: Boolean) {
        /*
         * Presentation motion is also the correct local getStats demand. Keep
         * decoder/jitter feedback fast without sending a fake InteractionState
         * to the host. Retry the idempotent session update even when the render
         * demand itself did not change, because service attachment may race the
         * first presentation window.
         */
        session()?.setPresentationMotionActive(active)

        if (renderPassivePriorityActive == active) return
        renderPassivePriorityActive = active
        updateRenderPriority()
    }

    private fun resetPassiveRenderPriority() {
        mainHandler.removeCallbacks(passiveRenderPriorityExpiry)
        passiveRenderMotion.reset()
        setRenderPassivePriority(false)
    }

    private fun updateRenderPriority() {
        val active =
            renderTouchPriorityActive ||
                renderPassivePriorityActive
        if (renderInteractionPriorityActive == active) return
        renderInteractionPriorityActive = active
        applyRenderThreadPriority()
    }

    private fun applyRenderThreadPriority(
        thread: EglThread? = renderEglThread
    ) {
        thread?.handler?.post {
            Process.setThreadPriority(
                RealtimeMediaPolicy.threadPriority(
                    renderInteractionPriorityActive
                )
            )
        }
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
        upY: Float,
        upEventTimeMs: Long
    ) {
        val rawDuration =
            RemoteGestureTiming.durationMs(
                startEventTimeMs = downAt,
                endEventTimeMs = upEventTimeMs,
                minMs = 1,
                maxMs = 2_500
            )
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
                    index.toLong() * lastIndex /
                        (MAX_GESTURE_POINTS - 1)
                    ).toInt()
            result += gesturePoints[sourceIndex]
        }
        return result
    }

    private fun updateMultiTouch(event: MotionEvent) {
        val firstIndex = event.findPointerIndex(firstPointerId)
        val secondIndex = event.findPointerIndex(secondPointerId)

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
        geometry: RemoteGeometry,
        eventTimeMs: Long
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
            RemoteGestureTiming.durationMs(
                startEventTimeMs = multiDownAt,
                endEventTimeMs = eventTimeMs,
                minMs = 80,
                maxMs = 2_500
            )

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
            viewWidth = rendererContainer.width.toFloat(),
            viewHeight = rendererContainer.height.toFloat(),
            remoteWidth = geometry.widthPx,
            remoteHeight = geometry.heightPx,
            frameWidth = candidateFrameWidth,
            frameHeight = candidateFrameHeight,
            clampToContent = clampToContent
        )
    }

    private fun session(): ControllerWebRtcSession? =
        ControllerConnectionRuntime.activeSession(sessionId)

    private fun dp(value: Int): Int =
        AarisUi.dp(activity, value)

    companion object {
        private const val FIRST_FRAME_DEADLINE_MS = 3_500L
        private const val MEDIA_RECOVERY_RETRY_MS = 4_000L
        private const val RENDER_RECOVERY_RETRY_MS = 2_500L
        private const val RENDER_HEALTH_CHECK_INTERVAL_MS = 1_500L
        private const val MAX_MEDIA_RECOVERY_ATTEMPTS = 2
        private const val MAX_RENDERER_RECOVERY_ATTEMPTS = 2

        private const val CONTROLS_AUTO_HIDE_MS = 3_500L
        private const val HANDLE_EDGE_MARGIN_DP = 8
        private const val HANDLE_SNAP_MS = 140L
        private const val HANDLE_PEEK_DELAY_MS = 450L
        private const val HANDLE_PEEK_ANIMATION_MS = 120L
        private const val HANDLE_PEEK_DP = 8
        private const val HANDLE_PEEK_ALPHA = 0.38f
        private const val REMOTE_MOTION_TAIL_MS = 1_500L
        // Match the host's PassiveMotionPriority tail so the final EGL stage
        // does not lose scheduler priority while a fling/video animation is
        // still producing fresh remote-screen frames.
        private const val PASSIVE_RENDER_PRIORITY_TAIL_MS = 3_000L
        private const val PRESENTATION_HEARTBEAT_INTERVAL_MS = 500L

        private const val MIN_STREAM_SEGMENT_MS = 16
        private const val MAX_STREAM_SEGMENT_MS = 56
        private const val MAX_LIVE_STREAM_POINTS = 8

        private const val TOUCH_SAMPLE_INTERVAL_MS = 12L
        private const val MAX_LOCAL_GESTURE_POINTS = 192
        private const val MAX_GESTURE_POINTS = 64
        private const val MIN_REMOTE_GESTURE_MS = 80
        private const val MAX_REMOTE_GESTURE_MS = 650
    }
}
