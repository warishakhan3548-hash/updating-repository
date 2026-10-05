package com.aaris.remoteassist.capture

import android.content.Context
import android.media.projection.MediaProjection
import android.os.SystemClock
import com.aaris.remoteassist.webrtc.WebRtcRuntime
import com.aaris.remoteassist.webrtc.advanced.BoundedStalenessGate
import java.io.Closeable
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicBoolean
import org.webrtc.CapturerObserver
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoSource
import org.webrtc.VideoTrack

data class StalenessShadowSnapshot(
    val evaluatedFrames: Long,
    val wouldDropFrames: Long,
    val latestQueueDelayMs: Double?,
    val maxQueueDelayMs: Double?
) {
    val wouldDropRatio: Double
        get() =
            if (evaluatedFrames <= 0L) 0.0
            else wouldDropFrames.toDouble() / evaluatedFrames.toDouble()
}

class ScreenCaptureTrack(
    context: Context,
    grant: ProjectionGrant,
    private val onProjectionStopped: () -> Unit
) : Closeable {
    private val appContext = context.applicationContext
    private val factory = WebRtcRuntime.factory(appContext)
    private val eglBase = WebRtcRuntime.eglBase(appContext)
    private val closed = AtomicBoolean(false)
    private val snapshotSinks = CopyOnWriteArraySet<VideoSink>()
    private val sampleClock = CaptureSampleClock()

    /*
     * Queue residence is measured for every frame, but source-level stale-frame
     * rejection is enabled only during active remote interaction. Passive video
     * playback therefore keeps the normal WebRTC cadence, while a swipe/drag can
     * prefer a newer frame over an old frame already waiting behind encoder work.
     *
     * BoundedStalenessGate has hysteresis plus a starvation escape, so this is
     * not an unbounded "drop until healthy" path.
     */
    private val stalenessGate = BoundedStalenessGate()

    @Volatile
    private var realtimeFreshnessPriority = false
    private val stalenessShadowLock = Any()
    private var shadowEvaluatedFrames = 0L
    private var shadowWouldDropFrames = 0L
    private var shadowLatestQueueDelayMs: Double? = null
    private var shadowMaxQueueDelayMs: Double? = null

    private val capturer =
        ScreenCapturerAndroid(
            grant.data,
            object : MediaProjection.Callback() {
                override fun onStop() {
                    onProjectionStopped()
                }
            }
        )

    private val videoSource: VideoSource =
        factory.createVideoSource(true)

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

    private var sourceGeometry: StableCaptureGeometry? = null

    init {
        capturer.initialize(
            surfaceTextureHelper,
            appContext,
            object : CapturerObserver {
                override fun onCapturerStarted(success: Boolean) {
                    videoSource.capturerObserver.onCapturerStarted(success)
                }

                override fun onCapturerStopped() {
                    videoSource.capturerObserver.onCapturerStopped()
                }

                override fun onFrameCaptured(frame: VideoFrame) {
                    val nowNs = SystemClock.elapsedRealtimeNanos()
                    var admitLiveSample = true

                    WebRtcRuntime.latestEncoderTelemetry()
                        ?.queueDelayMs(nowNs)
                        ?.let { queueDelayMs ->
                            val wouldAdmit =
                                stalenessGate.admit(
                                    nowMs = nowNs / 1_000_000L,
                                    queueDelayMs = queueDelayMs
                                )
                            synchronized(stalenessShadowLock) {
                                shadowEvaluatedFrames += 1
                                if (!wouldAdmit) shadowWouldDropFrames += 1
                                shadowLatestQueueDelayMs = queueDelayMs
                                shadowMaxQueueDelayMs =
                                    maxOf(
                                        shadowMaxQueueDelayMs ?: 0.0,
                                        queueDelayMs
                                    )
                            }

                            /*
                             * During direct manipulation, an old screen frame is
                             * less valuable than the next fresh one. Reject it
                             * before VideoSource/encoder work only when measured
                             * queue residence proves staleness. Outside active
                             * interaction the exact same decision remains
                             * telemetry-only, preserving smooth passive video.
                             */
                            if (
                                realtimeFreshnessPriority &&
                                !wouldAdmit
                            ) {
                                admitLiveSample = false
                            }
                        }

                    if (admitLiveSample) {
                        // Admit the latency-critical RTP sample before auxiliary
                        // sinks. A slow snapshot conversion must never hold the
                        // current live frame behind non-primary work.
                        //
                        // forceFrame reuses the SurfaceTexture timestamp on a
                        // static screen. Give that new sample a monotonic
                        // timestamp so the native FPS adapter does not discard
                        // recovery requests.
                        val sampled =
                            VideoFrame(
                                frame.buffer,
                                frame.rotation,
                                sampleClock.timestamp(
                                    frame.timestampNs,
                                    System.nanoTime()
                                )
                            )
                        videoSource.capturerObserver.onFrameCaptured(sampled)
                    }

                    /*
                     * Snapshot consumers remain independent from RTP admission.
                     * AI validation and compatibility recovery still receive a
                     * requested current frame even when the live encoder queue is
                     * intentionally shedding a stale sample.
                     */
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
        videoSource.adaptOutputFormat(
            profile.captureWidthPx,
            profile.captureHeightPx,
            profile.fps
        )

        capturer.startCapture(
            profile.captureWidthPx,
            profile.captureHeightPx,
            profile.fps
        )
        started = true
    }

    fun update(profile: CaptureProfile) {
        if (closed.get() || !started) return
        videoSource.adaptOutputFormat(
            profile.captureWidthPx,
            profile.captureHeightPx,
            profile.fps
        )

        val source = sourceGeometry ?: return
        // ScreenCapturerAndroid ignores FPS and recreates/resizes the virtual
        // display even for unchanged dimensions. Rebinding on every touch or
        // bitrate tier change can corrupt OEM mirroring scale. Adapt the video
        // source instead; only actual display rotation/resize touches capture.
        if (source.updateDisplay(profile)) {
            capturer.changeCaptureFormat(
                source.width,
                source.height,
                profile.fps
            )
        }
    }

    fun consumeStalenessShadowSnapshot(): StalenessShadowSnapshot =
        synchronized(stalenessShadowLock) {
            StalenessShadowSnapshot(
                evaluatedFrames = shadowEvaluatedFrames,
                wouldDropFrames = shadowWouldDropFrames,
                latestQueueDelayMs = shadowLatestQueueDelayMs,
                maxQueueDelayMs = shadowMaxQueueDelayMs
            ).also {
                shadowEvaluatedFrames = 0L
                shadowWouldDropFrames = 0L
                shadowMaxQueueDelayMs = shadowLatestQueueDelayMs
            }
        }

    fun setRealtimeFreshnessPriority(active: Boolean) {
        if (closed.get() || realtimeFreshnessPriority == active) return

        /*
         * A new interaction epoch must not inherit the previous epoch's drop
         * state or starvation timer. Reset first, then publish the new mode.
         * BoundedStalenessGate is synchronized, so reset is safe against the
         * SurfaceTexture capture callback.
         */
        stalenessGate.reset()
        realtimeFreshnessPriority = active
    }

    fun addSnapshotSink(sink: VideoSink) {
        snapshotSinks += sink
    }

    fun removeSnapshotSink(sink: VideoSink) {
        snapshotSinks -= sink
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
        snapshotSinks.clear()
        realtimeFreshnessPriority = false
        stalenessGate.reset()

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
