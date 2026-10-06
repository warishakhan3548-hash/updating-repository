package com.aaris.remoteassist.webrtc

import android.os.Process

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
    const val VIDEO_STATS_REALTIME_INTERVAL_MS = 500L
    const val VIDEO_STATS_IDLE_INTERVAL_MS = 1_500L

    fun videoStatsIntervalMs(realtime: Boolean): Long =
        if (realtime) {
            VIDEO_STATS_REALTIME_INTERVAL_MS
        } else {
            VIDEO_STATS_IDLE_INTERVAL_MS
        }

    fun threadPriority(interactionActive: Boolean): Int =
        if (interactionActive) {
            Process.THREAD_PRIORITY_DISPLAY
        } else {
            Process.THREAD_PRIORITY_DEFAULT
        }
}
