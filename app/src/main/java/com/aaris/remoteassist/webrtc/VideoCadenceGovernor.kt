package com.aaris.remoteassist.webrtc

/** Bounds capture cost; libwebrtc still owns bitrate, pacing and congestion control. */
class VideoCadenceGovernor(private val maxFps: Int) {
    @Volatile var cap = maxFps
        private set
    private var pressure = 0
    private var healthy = 0
    private var changedAt = Long.MIN_VALUE / 2

    fun observe(outbound: VideoHealthSnapshot, receiver: VideoHealthWindow?, requestedFps: Int, nowMs: Long): Boolean {
        val sender = outbound.recent ?: return false
        val budgetMs = 1000.0 / requestedFps.coerceAtLeast(1)
        // Hardware codecs can pipeline several frames. Time per frame above
        // the frame interval alone does not prove the pipeline is falling behind.
        val codecPressure = (sender.frames >= 5 && (sender.processingMs ?: 0.0) > budgetMs * 0.85 &&
            sender.fps < requestedFps * 0.85) ||
            (receiver != null && receiver.frames >= 5 && (receiver.processingMs ?: 0.0) > budgetMs * 0.85 &&
                receiver.fps < minOf(requestedFps.toDouble(), sender.fps) * 0.85)
        val loss = outbound.packetLossRatio ?: 0.0
        val receiverDrops = receiver?.let { (it.dropped ?: 0) >= 3 && (it.dropped ?: 0) > (it.frames + (it.dropped ?: 0)) * 0.12 } ?: false
        val receiverDelay = receiver?.let { (it.jitterMs ?: 0.0) > 100 && ((it.freezes ?: 0) > 0 || receiverDrops) } ?: false
        val congestion = loss >= 0.06 || (outbound.roundTripTimeMs ?: 0) >= 650 ||
            (sender.sendQueueMs ?: 0.0) > 80 || receiverDelay
        val overloaded = codecPressure || receiverDrops || congestion || outbound.qualityLimitationReason == "cpu"
        if (overloaded) {
            healthy = 0; pressure++
            if (pressure < 2 || nowMs - changedAt < 3000) return false
            val next = listOf(60, 30, 24, 20, 15).firstOrNull { it < minOf(cap, requestedFps) } ?: return false
            cap = next; changedAt = nowMs; pressure = 0
            return true
        }
        pressure = 0
        // Missing telemetry and a static screen are not evidence of spare capacity.
        val receiverHealthy = if (receiver == null) outbound.qualityLimitationReason == "none" &&
            outbound.roundTripTimeMs != null && outbound.roundTripTimeMs < 300 else
            receiver.frames >= 5 && receiver.processingMs != null && receiver.processingMs < budgetMs * 0.55 &&
                (receiver.jitterMs ?: 0.0) < 70 && (receiver.dropped ?: 0) == 0 && (receiver.freezes ?: 0) == 0
        val headroom = sender.frames >= 5 && sender.processingMs != null && sender.processingMs < budgetMs * 0.55 && receiverHealthy &&
            loss < 0.025 && (sender.sendQueueMs ?: 0.0) < 30 && outbound.qualityLimitationReason != "bandwidth"
        healthy = if (headroom) healthy + 1 else 0
        if (healthy < (if (receiver == null) 16 else 8) || nowMs - changedAt < 12_000) return false
        val next = listOf(15, 20, 24, 30, 60).firstOrNull { it > cap && it <= maxFps } ?: return false
        cap = next; changedAt = nowMs; healthy = 0
        return true
    }

    fun mayReduceResolution(nowMs: Long) = cap <= 24 && nowMs - changedAt >= 6000
}
