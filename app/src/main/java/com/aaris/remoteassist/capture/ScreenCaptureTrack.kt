package com.aaris.remoteassist.capture

import android.content.Context
import android.media.projection.MediaProjection
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import com.aaris.remoteassist.webrtc.WebRtcRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

class ScreenCaptureTrack(
    context: Context,
    grant: ProjectionGrant,
    private val onProjectionStopped: () -> Unit,
    private val onFirstFrame: () -> Unit = {}
) : Closeable {
    private val appContext = context.applicationContext
    private val factory = WebRtcRuntime.factory(appContext)
    private val eglBase = WebRtcRuntime.eglBase(appContext)
    private val closed = AtomicBoolean(false)
    private val firstFrameDelivered = AtomicBoolean(false)

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

    private val firstFrameSink = object : VideoSink {
        override fun onFrame(frame: VideoFrame) {
            if (firstFrameDelivered.compareAndSet(false, true)) {
                runCatching { videoTrack.removeSink(this) }
                onFirstFrame()
            }
        }
    }

    @Volatile
    private var started = false

    init {
        capturer.initialize(
            surfaceTextureHelper,
            appContext,
            videoSource.capturerObserver
        )
        videoTrack.setEnabled(true)
        videoTrack.addSink(firstFrameSink)
    }

    fun start(profile: CaptureProfile) {
        check(!closed.get())
        if (started) return

        capturer.startCapture(
            profile.captureWidthPx,
            profile.captureHeightPx,
            profile.fps
        )
        started = true
    }

    fun update(profile: CaptureProfile) {
        if (closed.get() || !started) return

        capturer.changeCaptureFormat(
            profile.captureWidthPx,
            profile.captureHeightPx,
            profile.fps
        )
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        if (started) {
            runCatching { capturer.stopCapture() }
            started = false
        }

        runCatching { videoTrack.removeSink(firstFrameSink) }
        runCatching { videoTrack.setEnabled(false) }
        runCatching { videoTrack.dispose() }

        // Stop/dispose the producer before its VideoSource observer. This
        // avoids late capturer callbacks targeting an already-disposed source.
        runCatching { capturer.dispose() }
        runCatching { videoSource.dispose() }
        runCatching { surfaceTextureHelper.dispose() }
    }
}
