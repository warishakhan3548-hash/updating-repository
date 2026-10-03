package com.aaris.remoteassist.capture

import android.content.Context
import android.media.projection.MediaProjection
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.CapturerObserver
import java.util.concurrent.CopyOnWriteArraySet
import com.aaris.remoteassist.webrtc.WebRtcRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

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

    private val capturer = ScreenCapturerAndroid(
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
                override fun onCapturerStarted(success: Boolean) { videoSource.capturerObserver.onCapturerStarted(success) }
                override fun onCapturerStopped() { videoSource.capturerObserver.onCapturerStopped() }
                override fun onFrameCaptured(frame: VideoFrame) {
                    snapshotSinks.forEach { sink -> runCatching { sink.onFrame(frame) } }
                    // forceFrame reuses the SurfaceTexture timestamp on a static
                    // screen. Give that new sample a monotonic timestamp so the
                    // native FPS adapter does not discard recovery requests.
                    val sampled = VideoFrame(frame.buffer, frame.rotation,
                        sampleClock.timestamp(frame.timestampNs, System.nanoTime()))
                    videoSource.capturerObserver.onFrameCaptured(sampled)
                }
            }
        )
        videoTrack.setEnabled(true)
    }

    fun start(profile: CaptureProfile) {
        check(!closed.get())
        if (started) return
        sourceGeometry = StableCaptureGeometry(profile)
        videoSource.adaptOutputFormat(profile.captureWidthPx, profile.captureHeightPx, profile.fps)

        capturer.startCapture(
            profile.captureWidthPx,
            profile.captureHeightPx,
            profile.fps
        )
        started = true
    }

    fun update(profile: CaptureProfile) {
        if (closed.get() || !started) return
        videoSource.adaptOutputFormat(profile.captureWidthPx, profile.captureHeightPx, profile.fps)

        val source = sourceGeometry ?: return
        // ScreenCapturerAndroid ignores FPS and recreates/resizes the virtual
        // display even for unchanged dimensions. Rebinding on every touch or
        // bitrate tier change can corrupt OEM mirroring scale. Adapt the video
        // source instead; only actual display rotation/resize touches capture.
        if (source.updateDisplay(profile)) {
            capturer.changeCaptureFormat(source.width, source.height, profile.fps)
        }
    }

    fun addSnapshotSink(sink: VideoSink) { snapshotSinks += sink }
    fun removeSnapshotSink(sink: VideoSink) { snapshotSinks -= sink }
    fun requestSnapshot() {
        check(started && !closed.get()) { "CAPTURE_STOPPED" }
        // Static Android screens may emit no new frames. forceFrame reads the
        // current SurfaceTexture on its owning thread without a second projection.
        // Snapshot sinks run before native frame-rate adaptation can drop duplicates.
        surfaceTextureHelper.forceFrame()
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
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
