package com.aaris.remoteassist.capture

import android.content.Context
import android.media.projection.MediaProjection
import android.os.Build
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.CapturerObserver
import java.util.concurrent.CopyOnWriteArraySet
import com.aaris.remoteassist.webrtc.RealtimeMediaPolicy
import com.aaris.remoteassist.webrtc.WebRtcRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

class ScreenCaptureTrack(
    context: Context,
    grant: ProjectionGrant,
    private val onProjectionStopped: () -> Unit,
    private val onSourceMotion: () -> Unit = {},
    private val onSourceGeometryChanged: (Int, Int) -> Unit = { _, _ -> }
) : Closeable {
    private val appContext = context.applicationContext
    private val factory = WebRtcRuntime.factory(appContext)
    private val eglBase = WebRtcRuntime.eglBase(appContext)
    private val closed = AtomicBoolean(false)
    private val realtimePriorityActive = AtomicBoolean(false)
    private val snapshotSinks = CopyOnWriteArraySet<VideoSink>()
    private val sampleClock = CaptureSampleClock()
    private val activityTracker = CaptureActivityTracker()
    private val refreshPolicy = CaptureRefreshPolicy()

    private val capturer = ScreenCapturerAndroid(
        grant.data,
        object : MediaProjection.Callback() {
            override fun onStop() {
                onProjectionStopped()
            }
        }
    )

    // This flag selects the encoder's content mode, not the capture permission
    // or producer. Native screencast mode disables quality scaling even when
    // the sender requests MAINTAIN_FRAMERATE. Remote-control motion needs the
    // realtime encoder path, with MediaProjection still supplying the pixels.
    // Keep it fixed for the session: toggling it recreates the encoder.
    private val videoSource: VideoSource =
        factory.createVideoSource(false)

    private val surfaceTextureHelper =
        checkNotNull(
            SurfaceTextureHelper.create(
                "AarisScreenCapture",
                eglBase.eglBaseContext
            )
        )

    val videoTrack: VideoTrack =
        factory.createVideoTrack(
            "aaris-screen-video",
            videoSource
        )

    @Volatile
    private var started = false
    private var lastObservedSourceWidth = 0
    private var lastObservedSourceHeight = 0
    private var sourceGeometry: StableCaptureGeometry? = null
    private var outputFormat: Triple<Int, Int, Int>? = null

    private val idleRefresh = object : Runnable {
        override fun run() {
            if (closed.get() || !started) return
            if (refreshPolicy.shouldRefresh(android.os.SystemClock.elapsedRealtime())) {
                // forceFrame samples the current texture on its owner thread.
                // No retained frame, second projection, or CPU readback is needed.
                surfaceTextureHelper.forceFrame()
            }
            surfaceTextureHelper.handler.postDelayed(this, CaptureRefreshPolicy.INTERVAL_MS)
        }
    }

    init {
        capturer.initialize(
            surfaceTextureHelper,
            appContext,
            object : CapturerObserver {
                override fun onCapturerStarted(success: Boolean) { videoSource.capturerObserver.onCapturerStarted(success) }
                override fun onCapturerStopped() { videoSource.capturerObserver.onCapturerStopped() }
                override fun onFrameCaptured(frame: VideoFrame) {
                    refreshPolicy.onSample(
                        android.os.SystemClock.elapsedRealtime(),
                        frame.timestampNs
                    )

                    /*
                     * MediaProjection/OEM rotation callbacks are not perfectly
                     * reliable while a fullscreen game owns the display. The
                     * actual producer frame is authoritative geometry evidence.
                     * Publish only when the oriented source dimensions change;
                     * this is O(1), allocates nothing on steady-state frames and
                     * never waits on policy work.
                     */
                    val observedWidth = frame.rotatedWidth
                    val observedHeight = frame.rotatedHeight
                    if (
                        observedWidth > 0 &&
                        observedHeight > 0 &&
                        (
                            observedWidth != lastObservedSourceWidth ||
                                observedHeight != lastObservedSourceHeight
                            )
                    ) {
                        lastObservedSourceWidth = observedWidth
                        lastObservedSourceHeight = observedHeight
                        runCatching {
                            onSourceGeometryChanged(
                                observedWidth,
                                observedHeight
                            )
                        }
                    }
                    // Admit the latency-critical RTP sample first. Auxiliary
                    // sinks are best-effort consumers (fallback recovery / AI
                    // snapshots); a slow conversion or retain must never hold
                    // the current live frame behind non-primary work.
                    //
                    // forceFrame reuses the SurfaceTexture timestamp on a static
                    // screen. Give that new sample a monotonic timestamp so the
                    // native FPS adapter does not discard recovery requests.
                    val sampledTimestampNs =
                        sampleClock.timestamp(
                            frame.timestampNs,
                            System.nanoTime()
                        )
                    if (sampledTimestampNs == frame.timestampNs) {
                        // Natural frames already carry a valid monotonic
                        // timestamp. Forward the producer-owned frame directly
                        // so the 30/45/60 fps hot path allocates no wrapper.
                        videoSource.capturerObserver.onFrameCaptured(frame)
                    } else {
                        // forceFrame may repeat the SurfaceTexture timestamp.
                        // Only that recovery path needs a timestamp wrapper.
                        videoSource.capturerObserver.onFrameCaptured(
                            VideoFrame(
                                frame.buffer,
                                frame.rotation,
                                sampledTimestampNs
                            )
                        )
                    }
                    if (activityTracker.onFrame(frame.timestampNs)) {
                        // The callback is throttled by CaptureActivityTracker.
                        // Keep it best-effort and never let policy work block
                        // the latency-critical capture/RTP path.
                        runCatching { onSourceMotion() }
                    }

                    // These sinks are invoked explicitly for every capturer
                    // callback, even when WebRTC adaptation elects not to send
                    // the corresponding RTP frame.
                    snapshotSinks.forEach { sink ->
                        runCatching { sink.onFrame(frame) }
                    }
                }
            }
        )
        videoTrack.setEnabled(true)
    }

    fun start(profile: CaptureProfile) {
        check(!closed.get())
        if (started) return
        sourceGeometry = StableCaptureGeometry(profile)
        activityTracker.sampleFps(android.os.SystemClock.elapsedRealtime())
        adaptOutput(profile)

        capturer.startCapture(
            profile.captureWidthPx,
            profile.captureHeightPx,
            profile.fps
        )
        started = true
        // Realtime encoder mode has no screencast frame repeater. A sparse
        // sample keeps still screens from looking like a dead RTP/decoder path
        // to the controller's liveness and first-frame watchdogs.
        surfaceTextureHelper.handler.postDelayed(idleRefresh, CaptureRefreshPolicy.INTERVAL_MS)
    }

    fun update(profile: CaptureProfile) {
        if (closed.get() || !started) return
        adaptOutput(profile)

        val source = sourceGeometry ?: return

        /*
         * ScreenCapturerAndroid ignores the FPS argument. On Android 12+ its
         * changeCaptureFormat() path resizes the existing VirtualDisplay;
         * before Android 12 it recreates the display, which is where vendor
         * mirroring-scale regressions have historically appeared.
         *
         * Let the producer follow our already-hysteresis-gated spatial budget
         * only on the safe resize path. This moves pixel relief in front of
         * SurfaceTexture/GPU production instead of scaling an expensive native
         * frame only after it has already been captured.
         */
        val allowAdaptiveProducerResize =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        if (source.update(profile, allowAdaptiveProducerResize)) {
            capturer.changeCaptureFormat(
                source.width,
                source.height,
                profile.fps
            )
        }
    }

    private fun adaptOutput(profile: CaptureProfile) {
        val next = Triple(profile.captureWidthPx, profile.captureHeightPx, profile.fps)
        if (next == outputFormat) return
        videoSource.adaptOutputFormat(next.first, next.second, next.third)
        outputFormat = next
    }

    fun addSnapshotSink(sink: VideoSink) { snapshotSinks += sink }

    internal fun sampleSourceCadence(nowMs: Long): CaptureCadenceWindow? =
        activityTracker.sample(nowMs)

    fun sampleSourceFps(nowMs: Long): Double? =
        activityTracker.sampleFps(nowMs)

    fun removeSnapshotSink(sink: VideoSink) { snapshotSinks -= sink }

    /**
     * Give the SurfaceTexture delivery lane a temporary scheduling advantage
     * whenever fresh screen motion is latency-critical. The caller owns the
     * authoritative freshness state (remote input OR observed source motion),
     * so inertial scrolling/video/game animation does not lose scheduling
     * priority immediately when a finger lifts.
     *
     * This does not create frames or increase encoder work; it only reduces
     * scheduler jitter between SurfaceTexture availability and libwebrtc's
     * capture observer. Read the newest requested state on the owner thread so
     * rapid transitions cannot leave the thread permanently boosted.
     */
    fun setRealtimePriority(active: Boolean) {
        if (closed.get()) return
        if (realtimePriorityActive.getAndSet(active) == active) return

        surfaceTextureHelper.handler.post {
            if (closed.get()) return@post
            android.os.Process.setThreadPriority(
                RealtimeMediaPolicy.threadPriority(
                    realtimePriorityActive.get()
                )
            )
        }
    }

    fun armInteractionRefresh(
        nowMs: Long = android.os.SystemClock.elapsedRealtime()
    ) {
        if (closed.get() || !started) return
        refreshPolicy.onInteractionApplied(nowMs)
    }

    fun requestInteractionRefresh(
        nowMs: Long = android.os.SystemClock.elapsedRealtime()
    ): Boolean {
        if (closed.get() || !started) return false
        if (!refreshPolicy.shouldRefreshForInteraction(nowMs)) return false
        // forceFrame runs on SurfaceTextureHelper's owner thread and feeds the
        // same zero-copy RTP source; it does not create a second projection.
        surfaceTextureHelper.forceFrame()
        return true
    }

    fun requestSnapshot() {
        check(started && !closed.get()) { "CAPTURE_STOPPED" }
        // Static Android screens may emit no new frames. forceFrame reads the
        // current SurfaceTexture on its owning thread without a second projection.
        // Snapshot sinks receive the forced callback even when native adaptation
        // decides not to forward the duplicate into RTP.
        surfaceTextureHelper.forceFrame()
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        realtimePriorityActive.set(false)
        surfaceTextureHelper.handler.removeCallbacks(idleRefresh)
        snapshotSinks.clear()

        if (started) {
            runCatching { capturer.stopCapture() }
            started = false
        }

        runCatching { videoTrack.setEnabled(false) }
        runCatching { videoTrack.dispose() }

        // Stop/dispose the producer before its VideoSource observer. This
        // avoids late capturer callbacks targeting an already-disposed source.
        runCatching { capturer.dispose() }
        runCatching { videoSource.dispose() }
        runCatching { surfaceTextureHelper.dispose() }
    }
}
