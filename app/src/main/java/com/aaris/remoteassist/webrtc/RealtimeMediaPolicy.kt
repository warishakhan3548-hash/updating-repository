package com.aaris.remoteassist.webrtc

import android.os.Process
import org.webrtc.Priority
import org.webrtc.RtpParameters

/**
 * Cross-layer realtime policy for remote-control video.
 *
 * The product is latency-sensitive interactive streaming, not buffered media:
 * keep WebRTC's receiver in its low-latency playout path while leaving a small
 * jitter budget, and temporarily favor capture/render scheduling only while the
 * controller is actively manipulating the remote phone.
 */
internal object RealtimeMediaPolicy {
    const val PLAYOUT_DELAY_MIN_MS = 0
    const val PLAYOUT_DELAY_MAX_MS = 100

    /*
     * Interactive remoting is a single latency-sensitive video stream. DSCP is
     * intentionally a transport classification only: GCC/TWCC still owns the
     * send rate, MotionVideoBudget still owns our pixel ladder, and this does
     * not raise min bitrate or create more encoded frames.
     */
    const val ENABLE_VIDEO_DSCP = true
    const val VIDEO_NETWORK_PRIORITY = Priority.HIGH

    const val FIELD_TRIALS =
        "WebRTC-ForceSendPlayoutDelay/min_ms:0,max_ms:100/"

    /*
     * getStats() is diagnostic/adaptation work, not part of the media hot path.
     * During touch/motion we sample often enough to react before a stale queue
     * survives a full second. While the screen is quiet, sample less often so
     * telemetry itself does not become steady-state CPU/battery overhead.
     */
    const val VIDEO_STATS_INITIAL_DELAY_MS = 650L
    const val VIDEO_STATS_FAST_KICK_MS = 100L

    /*
     * A risky producer upshift deserves one early measurement after the new
     * sender/source envelope is live. This is not a faster polling mode: it
     * simply pulls the already-existing single-flight stats loop forward once,
     * then normal realtime/idle cadence resumes.
     *
     * 120 ms gives a 45/60 fps trial several frames to reach the encoder/pacer
     * while staying well below the ordinary 500 ms interaction interval.
     */
    const val VIDEO_STATS_RECONFIGURE_KICK_MS = 120L
    const val VIDEO_STATS_REALTIME_INTERVAL_MS = 500L
    const val VIDEO_STATS_IDLE_INTERVAL_MS = 1_500L

    fun videoStatsIntervalMs(realtime: Boolean): Long =
        if (realtime) {
            VIDEO_STATS_REALTIME_INTERVAL_MS
        } else {
            VIDEO_STATS_IDLE_INTERVAL_MS
        }

    /**
     * Keep one authority over interactive spatial/temporal adaptation.
     *
     * MotionVideoBudget + HighCadenceProbe already own the app's source
     * resolution/FPS envelope. Letting libwebrtc independently resize the same
     * motion stream creates two feedback controllers acting on one plant, which
     * can cause hidden resolution oscillation and repeated codec reconfiguration.
     *
     * Modern libwebrtc exposes MAINTAIN_FRAMERATE_AND_RESOLUTION specifically
     * for applications that implement their own adaptation policy. WebRTC still
     * owns congestion control, packet pacing, encoder rate control and may drop
     * work before encode when resources are overused; our measured cross-layer
     * governor then lowers the declared rung when pressure persists.
     */
    fun videoDegradationPreference(
        motionPriority: Boolean,
        preserveResolution: Boolean
    ): RtpParameters.DegradationPreference =
        when {
            motionPriority ->
                RtpParameters.DegradationPreference.MAINTAIN_FRAMERATE_AND_RESOLUTION
            preserveResolution ->
                RtpParameters.DegradationPreference.MAINTAIN_RESOLUTION
            else ->
                RtpParameters.DegradationPreference.BALANCED
        }

    /**
     * Identify transitions that can expose a new codec/pacer throughput limit.
     * The result only requests one earlier health sample; it never changes media
     * cadence, bitrate, or queueing by itself.
     */
    fun shouldKickVideoStatsAfterTransition(
        previousWidthPx: Int,
        previousHeightPx: Int,
        previousFps: Int,
        nextWidthPx: Int,
        nextHeightPx: Int,
        nextFps: Int
    ): Boolean {
        /*
         * Startup already owns an initial health probe. Only a real, seeded
         * transition can request this extra one-shot measurement.
         */
        if (
            previousWidthPx <= 0 ||
            previousHeightPx <= 0 ||
            previousFps <= 0 ||
            nextWidthPx <= 0 ||
            nextHeightPx <= 0 ||
            nextFps <= 0
        ) {
            return false
        }

        val previousPixelRate =
            previousWidthPx.toLong() *
                previousHeightPx.toLong() *
                previousFps.toLong()
        val nextPixelRate =
            nextWidthPx.toLong() *
                nextHeightPx.toLong() *
                nextFps.toLong()

        /*
         * Higher temporal cadence can stress codec/driver scheduling even when
         * resolution was reduced enough to keep total pixel-rate flat. Treat it
         * as risky independently from the aggregate pixel-rate comparison.
         */
        return nextPixelRate > previousPixelRate ||
            nextFps > previousFps
    }

    /**
     * Order cross-layer video reconfiguration so a transition cannot create a
     * short producer burst that outruns the sender envelope.
     *
     * When pixel-rate demand grows, prime RTP/encoder limits first and only
     * then admit the faster/heavier source. When demand stays flat or shrinks,
     * reduce the source first so stale work stops entering the pipeline before
     * sender limits are tightened. This is deliberately a two-actuator ordering
     * rule, not another queue, encoder, or feedback loop.
     */
    fun senderBeforeCaptureForTransition(
        previousWidthPx: Int,
        previousHeightPx: Int,
        previousFps: Int,
        nextWidthPx: Int,
        nextHeightPx: Int,
        nextFps: Int
    ): Boolean {
        if (
            previousWidthPx <= 0 ||
            previousHeightPx <= 0 ||
            previousFps <= 0
        ) {
            return true
        }

        val previousPixelRate =
            previousWidthPx.toLong() *
                previousHeightPx.toLong() *
                previousFps.coerceAtLeast(1).toLong()
        val nextPixelRate =
            nextWidthPx.coerceAtLeast(1).toLong() *
                nextHeightPx.coerceAtLeast(1).toLong() *
                nextFps.coerceAtLeast(1).toLong()

        return nextPixelRate > previousPixelRate ||
            (
                nextPixelRate == previousPixelRate &&
                    nextFps > previousFps
                )
    }

    fun threadPriority(interactionActive: Boolean): Int =
        if (interactionActive) {
            Process.THREAD_PRIORITY_DISPLAY
        } else {
            Process.THREAD_PRIORITY_DEFAULT
        }
}
