package com.aaris.remoteassist.webrtc

import android.os.Process
import org.webrtc.Priority
import org.webrtc.RtpParameters

/**
 * Cross-layer realtime policy for remote-control video.
 *
 * Keep one timing authority per stage. Pinned libwebrtc M150 owns RTP ordering,
 * repair, adaptive jitter timing and timed decode; the controller EGL path owns
 * the final display/vsync admission with latest-frame-wins semantics. Do not add
 * a second Java-side decoded-frame queue or a second timestamp-smoothing stage.
 */
internal object RealtimeMediaPolicy {
    const val PLAYOUT_DELAY_MIN_MS = 10
    const val PLAYOUT_DELAY_MAX_MS = 500

    /*
     * Interactive remoting is a single latency-sensitive video stream. DSCP is
     * intentionally a transport classification only: GCC/TWCC still owns the
     * send rate, MotionVideoBudget still owns our pixel ladder, and this does
     * not raise min bitrate or create more encoded frames.
     */
    const val ENABLE_VIDEO_DSCP = true
    const val VIDEO_NETWORK_PRIORITY = Priority.HIGH

    /*
     * Do not force M150's min=0 "render as soon as possible" path for WAN
     * remoting. That path intentionally bypasses timestamp-based render timing;
     * its 8 ms decode pacing protects the decoder from bursts, but it does not
     * smooth irregular packet arrival. A small positive floor keeps latency
     * bounded while allowing native jitter/timestamp timing to absorb ordinary
     * mobile/TURN variance before the frame reaches the vsync-aligned EGL lane.
     *
     * max=500 is only a best-effort recovery ceiling, not a fixed half-second
     * hold. WebRTC remains the single owner of packet/jitter buffering and timed
     * decode; the app still retains no second decoded-frame playback queue.
     */
    const val FIELD_TRIALS =
        "WebRTC-ForceSendPlayoutDelay/min_ms:10,max_ms:500/"

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
     * Single authoritative source-cadence ceiling.
     *
     * CaptureProfile encodes the device class budget (for example LOW=20 fps
     * motion, BALANCED=30 fps, STANDARD/HIGH=60 fps). The session-wide cadence
     * governor is intentionally capable of 60 fps so premium devices can probe
     * upward, but that capability must never override the active profile.
     *
     * Keeping this invariant in one pure function prevents a healthy-network
     * promotion from turning a weak phone into an overloaded 30/60 fps encoder
     * and creating the exact smooth -> stutter -> recover oscillation that
     * freshness control is meant to avoid.
     */
    fun effectiveSourceFps(
        idleFps: Int,
        motionFps: Int,
        cadenceCap: Int,
        deviceFpsLimit: Int,
        freshnessActive: Boolean
    ): Int {
        val profileCeiling =
            if (freshnessActive) {
                motionFps
            } else {
                idleFps
            }
        return minOf(
            profileCeiling.coerceAtLeast(1),
            cadenceCap.coerceAtLeast(1),
            deviceFpsLimit.coerceAtLeast(1)
        )
    }

    /**
     * Stable RTP encoder framerate envelope.
     *
     * Dynamic cadence is owned by VideoSource.adaptOutputFormat() before encode.
     * Mirroring every cadence rung into RtpSender.maxFramerate creates a second
     * temporal actuator and can force avoidable sender/codec reconfiguration on
     * 30 -> 45/60 motion transitions. Keep the sender ceiling at the highest
     * cadence this profile + device + active codec operating point can sustain.
     *
     * The source still emits fewer frames whenever the cadence governor backs
     * off, so this ceiling never forces extra encoded frames.
     */
    fun senderFrameRateCeiling(
        motionFps: Int,
        deviceFpsLimit: Int,
        encoderFpsLimit: Int
    ): Int =
        minOf(
            motionFps.coerceAtLeast(1),
            deviceFpsLimit.coerceAtLeast(1),
            encoderFpsLimit.coerceAtLeast(1)
        )

    /**
     * Split fast native relief from the slower app-owned source envelope.
     *
     * MotionVideoBudget/HighCadenceProbe cap input pixels, FPS and bitrate
     * using end-to-end pressure measurements. Native overuse adaptation is
     * faster than those measurements: MAINTAIN_FRAMERATE allows libwebrtc to
     * sacrifice spatial detail inside the app's maximum capture envelope
     * before dropping temporal cadence. It cannot raise resolution beyond
     * that envelope; app-level recovery remains hysteresis-gated.
     *
     * No additional decoded-frame queue or Java-side codec scaler is added.
     * Non-motion callers can still select BALANCED / MAINTAIN_RESOLUTION.
     */
    fun videoDegradationPreference(
        motionPriority: Boolean,
        preserveResolution: Boolean
    ): RtpParameters.DegradationPreference =
        when {
            motionPriority ->
                RtpParameters.DegradationPreference.MAINTAIN_FRAMERATE
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
