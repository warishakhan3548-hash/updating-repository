from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def write(path, content):
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)


def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}: {old[:120]!r}")
    write(path, text.replace(old, new, 1))


# ---- version ----
replace_once(
    "app/build.gradle.kts",
    'versionCode = 92\n        versionName = "1.9.4"',
    'versionCode = 93\n        versionName = "1.9.5"',
)

# ---- actual controller presentation telemetry ----
write(
    "app/src/main/java/com/aaris/remoteassist/webrtc/PresentationCadenceTracker.kt",
    '''package com.aaris.remoteassist.webrtc

import kotlin.math.roundToInt

/** Actual controller-side EGL presentation cadence, not decoder/RTP cadence. */
data class PresentationCadenceWindow(
    val intervalMs: Int,
    val renderedFrames: Int,
    val maxGapMs: Int
) {
    init {
        require(intervalMs in 1..6_000)
        require(renderedFrames in 1..2_048)
        require(maxGapMs in 0..6_000)
    }

    val fps: Double
        get() = renderedFrames * 1000.0 / intervalMs

    fun compact(): String =
        "present=${fps.roundToInt()}fps maxGap=${maxGapMs}ms"
}

/**
 * Converts real EGL swaps into bounded one-second-ish windows. The tracker is
 * synchronized because EglRenderer invokes its render listener on a render
 * thread while session lifecycle/reset may run on Android's main thread.
 */
class PresentationCadenceTracker(
    private val minWindowMs: Long = 850L,
    private val maxGapMs: Long = 6_000L
) {
    init {
        require(minWindowMs in 500L..3_000L)
        require(maxGapMs in minWindowMs..6_000L)
    }

    private var windowStartMs = -1L
    private var lastFrameMs = -1L
    private var frames = 0
    private var largestGapMs = 0L

    @Synchronized
    fun onPresented(nowMs: Long): PresentationCadenceWindow? {
        if (nowMs < 0L) return null

        if (
            windowStartMs < 0L ||
            lastFrameMs < 0L ||
            nowMs < lastFrameMs ||
            nowMs - lastFrameMs > maxGapMs
        ) {
            windowStartMs = nowMs
            lastFrameMs = nowMs
            frames = 1
            largestGapMs = 0L
            return null
        }

        largestGapMs = maxOf(largestGapMs, nowMs - lastFrameMs)
        lastFrameMs = nowMs
        frames += 1

        val elapsed = nowMs - windowStartMs
        if (elapsed < minWindowMs) return null

        val sample = PresentationCadenceWindow(
            intervalMs = elapsed.coerceIn(1L, 6_000L).toInt(),
            renderedFrames = frames.coerceIn(1, 2_048),
            maxGapMs = largestGapMs.coerceIn(0L, 6_000L).toInt()
        )

        // The current frame closes the old window. The next frame starts the
        // new count, preventing one EGL swap from being counted twice.
        windowStartMs = nowMs
        frames = 0
        largestGapMs = 0L
        return sample
    }

    @Synchronized
    fun reset() {
        windowStartMs = -1L
        lastFrameMs = -1L
        frames = 0
        largestGapMs = 0L
    }
}
'''
)

# Video health window now carries optional real display-presentation telemetry.
write(
    "app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthWindow.kt",
    '''package com.aaris.remoteassist.webrtc

import kotlin.math.roundToInt

/** Interval deltas, never lifetime averages masquerading as current pressure. */
data class VideoHealthWindow(
    val intervalMs: Int,
    val frames: Int,
    val processingMs: Double?,
    val jitterMs: Double?,
    val dropped: Int?,
    val freezes: Int?,
    val bitrateBps: Long = 0,
    val sendQueueMs: Double? = null,
    val presentationIntervalMs: Int? = null,
    val presentedFrames: Int? = null,
    val maxRenderGapMs: Int? = null
) {
    val fps: Double get() = frames * 1000.0 / intervalMs
    val presentedFps: Double?
        get() {
            val interval = presentationIntervalMs ?: return null
            val count = presentedFrames ?: return null
            if (interval <= 0 || count < 0) return null
            return count * 1000.0 / interval
        }

    fun compact(): String {
        val presentation = presentedFps?.roundToInt()?.let { " present=${it}fps gap=${maxRenderGapMs}ms" }.orEmpty()
        return "${fps.roundToInt()}fps ${bitrateBps / 1000}kbps codec=${processingMs?.roundToInt()}ms jitter=${jitterMs?.roundToInt()}ms drop=$dropped freeze=$freezes queue=${sendQueueMs?.roundToInt()}ms$presentation"
    }
}

class VideoHealthWindowTracker {
    private var previous: VideoHealthSnapshot? = null

    @Synchronized fun sample(current: VideoHealthSnapshot): VideoHealthSnapshot {
        val old = previous
        previous = current
        if (old == null || current.streamId != old.streamId || current.direction != old.direction || current.codec != old.codec) return current
        val interval = (current.timestampUs - old.timestampUs) / 1000.0
        if (!interval.isFinite() || interval !in 500.0..6000.0) return current
        val frames = if (current.direction == "outbound") current.frames - old.frames else current.framesSecondary - old.framesSecondary
        val bytes = current.bytes - old.bytes
        val packets = current.packets - old.packets
        if (frames !in 0..2048 || bytes < 0 || packets < 0) return current
        fun average(total: Double?, before: Double?, count: Long): Double? {
            if (total == null || before == null || count <= 0) return null
            val delta = total - before
            return (delta * 1000 / count).takeIf { delta >= 0 && it.isFinite() && it in 0.0..5000.0 }
        }
        fun count(total: Long?, before: Long?): Int? = if (total == null || before == null) null else
            (total - before).takeIf { it in 0..2048 }?.toInt()
        return current.copy(recent = VideoHealthWindow(interval.roundToInt(), frames.toInt(),
            average(current.processingTotalSeconds, old.processingTotalSeconds, frames),
            average(current.jitterTotalSeconds, old.jitterTotalSeconds,
                if (current.jitterEmittedCount != null && old.jitterEmittedCount != null) current.jitterEmittedCount - old.jitterEmittedCount else 0),
            count(current.framesDropped, old.framesDropped), count(current.freezeCount, old.freezeCount),
            (bytes * 8000.0 / interval).toLong(), average(current.sendDelayTotalSeconds, old.sendDelayTotalSeconds, packets)))
    }
}
'''
)

write(
    "app/src/main/java/com/aaris/remoteassist/webrtc/ReceiverVideoFeedback.kt",
    '''package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket

/** One-use, lease-bound feedback. Old generations and buffered/replayed reports cannot tune video. */
class ReceiverVideoFeedback {
    private var identity: Pair<Long, Int>? = null
    private var lastSequence = 0L
    private var receivedAt = 0L
    private var pending: VideoHealthWindow? = null

    private var lastPresentationSequence = 0L
    private var presentationReceivedAt = 0L
    private var pendingPresentation: PresentationCadenceWindow? = null

    private fun bindIdentity(secret: Long, generation: Int) {
        val key = secret to generation
        if (identity == key) return
        identity = key
        lastSequence = 0L
        receivedAt = 0L
        pending = null
        lastPresentationSequence = 0L
        presentationReceivedAt = 0L
        pendingPresentation = null
    }

    fun accept(packet: ControlPacket.VideoFeedback, secret: Long, generation: Int, nowMs: Long): Boolean {
        if (!packet.valid() || packet.leaseSecret != secret || packet.generation != generation) return false
        bindIdentity(secret, generation)
        if (packet.sequence <= lastSequence) return false
        lastSequence = packet.sequence
        receivedAt = nowMs
        pending = VideoHealthWindow(
            packet.intervalMs,
            packet.decodedFrames,
            packet.decodeMs.takeIf { it >= 0 }?.toDouble(),
            packet.jitterMs.takeIf { it >= 0 }?.toDouble(),
            packet.droppedFrames.takeIf { it >= 0 },
            packet.freezeEvents.takeIf { it >= 0 }
        )
        return true
    }

    fun accept(packet: ControlPacket.PresentationFeedback, secret: Long, generation: Int, nowMs: Long): Boolean {
        if (!packet.valid() || packet.leaseSecret != secret || packet.generation != generation) return false
        bindIdentity(secret, generation)
        if (packet.sequence <= lastPresentationSequence) return false
        lastPresentationSequence = packet.sequence
        presentationReceivedAt = nowMs
        pendingPresentation = PresentationCadenceWindow(
            intervalMs = packet.intervalMs,
            renderedFrames = packet.renderedFrames,
            maxGapMs = packet.maxGapMs
        )
        return true
    }

    fun consume(secret: Long, generation: Int, nowMs: Long): VideoHealthWindow? {
        if (identity != secret to generation) return null

        val video = pending?.takeIf { nowMs - receivedAt in 0..MAX_AGE_MS }
        pending = null
        val presentation = pendingPresentation?.takeIf {
            nowMs - presentationReceivedAt in 0..MAX_AGE_MS
        }
        pendingPresentation = null

        if (video == null && presentation == null) return null
        val base = video ?: VideoHealthWindow(
            intervalMs = presentation!!.intervalMs,
            frames = 0,
            processingMs = null,
            jitterMs = null,
            dropped = null,
            freezes = null
        )
        return if (presentation == null) {
            base
        } else {
            base.copy(
                presentationIntervalMs = presentation.intervalMs,
                presentedFrames = presentation.renderedFrames,
                maxRenderGapMs = presentation.maxGapMs
            )
        }
    }

    private companion object {
        const val MAX_AGE_MS = 3_000L
    }
}
'''
)

# Wire packet type 20: additive/backward compatible with v1 packet framing.
protocol = "app/src/main/java/com/aaris/remoteassist/control/ControlProtocol.kt"
replace_once(
    protocol,
    '''    data class VideoFeedback(\n        val leaseSecret: Long, val generation: Int, val sequence: Long,\n        val intervalMs: Int, val decodedFrames: Int, val decodeMs: Float,\n        val jitterMs: Float, val droppedFrames: Int, val freezeEvents: Int\n    ) : ControlPacket {\n        fun valid() = sequence > 0 && intervalMs in 500..6000 && decodedFrames in 0..2048 &&\n            decodeMs.isFinite() && (decodeMs == -1f || decodeMs in 0f..5000f) &&\n            jitterMs.isFinite() && (jitterMs == -1f || jitterMs in 0f..5000f) &&\n            droppedFrames in -1..2048 && freezeEvents in -1..2048\n    }\n\n    data object Disconnect : ControlPacket''',
    '''    data class VideoFeedback(\n        val leaseSecret: Long, val generation: Int, val sequence: Long,\n        val intervalMs: Int, val decodedFrames: Int, val decodeMs: Float,\n        val jitterMs: Float, val droppedFrames: Int, val freezeEvents: Int\n    ) : ControlPacket {\n        fun valid() = sequence > 0 && intervalMs in 500..6000 && decodedFrames in 0..2048 &&\n            decodeMs.isFinite() && (decodeMs == -1f || decodeMs in 0f..5000f) &&\n            jitterMs.isFinite() && (jitterMs == -1f || jitterMs in 0f..5000f) &&\n            droppedFrames in -1..2048 && freezeEvents in -1..2048\n    }\n\n    data class PresentationFeedback(\n        val leaseSecret: Long,\n        val generation: Int,\n        val sequence: Long,\n        val intervalMs: Int,\n        val renderedFrames: Int,\n        val maxGapMs: Int\n    ) : ControlPacket {\n        fun valid() =\n            sequence > 0 &&\n                intervalMs in 500..6000 &&\n                renderedFrames in 1..2048 &&\n                maxGapMs in 0..6000\n    }\n\n    data object Disconnect : ControlPacket'''
)
replace_once(protocol, '    private const val VIDEO_FEEDBACK: Byte = 19\n', '    private const val VIDEO_FEEDBACK: Byte = 19\n    private const val PRESENTATION_FEEDBACK: Byte = 20\n')
replace_once(protocol, '        if (packet is ControlPacket.VideoFeedback) require(packet.valid())\n', '        if (packet is ControlPacket.VideoFeedback) require(packet.valid())\n        if (packet is ControlPacket.PresentationFeedback) require(packet.valid())\n')
replace_once(protocol, '            is ControlPacket.VideoFeedback -> 2 + 8 + 4 + 8 + 24\n            ControlPacket.Disconnect -> 2', '            is ControlPacket.VideoFeedback -> 2 + 8 + 4 + 8 + 24\n            is ControlPacket.PresentationFeedback -> 2 + 8 + 4 + 8 + 12\n            ControlPacket.Disconnect -> 2')
replace_once(protocol, '''            is ControlPacket.VideoFeedback -> {\n                putCommandHeader(buffer, packet.leaseSecret, packet.generation, packet.sequence)\n                buffer.putInt(packet.intervalMs); buffer.putInt(packet.decodedFrames)\n                buffer.putFloat(packet.decodeMs); buffer.putFloat(packet.jitterMs)\n                buffer.putInt(packet.droppedFrames); buffer.putInt(packet.freezeEvents)\n            }\n            ControlPacket.Disconnect -> Unit''', '''            is ControlPacket.VideoFeedback -> {\n                putCommandHeader(buffer, packet.leaseSecret, packet.generation, packet.sequence)\n                buffer.putInt(packet.intervalMs); buffer.putInt(packet.decodedFrames)\n                buffer.putFloat(packet.decodeMs); buffer.putFloat(packet.jitterMs)\n                buffer.putInt(packet.droppedFrames); buffer.putInt(packet.freezeEvents)\n            }\n            is ControlPacket.PresentationFeedback -> {\n                putCommandHeader(buffer, packet.leaseSecret, packet.generation, packet.sequence)\n                buffer.putInt(packet.intervalMs)\n                buffer.putInt(packet.renderedFrames)\n                buffer.putInt(packet.maxGapMs)\n            }\n            ControlPacket.Disconnect -> Unit''')
replace_once(protocol, '''                VIDEO_FEEDBACK -> {\n                    require(buffer.remaining() == 44)\n                    val header = readHeader(buffer)\n                    ControlPacket.VideoFeedback(header.leaseSecret, header.generation, header.sequence,\n                        buffer.int, buffer.int, buffer.float, buffer.float, buffer.int, buffer.int).also { require(it.valid()) }\n                }\n                DISCONNECT -> {''', '''                VIDEO_FEEDBACK -> {\n                    require(buffer.remaining() == 44)\n                    val header = readHeader(buffer)\n                    ControlPacket.VideoFeedback(header.leaseSecret, header.generation, header.sequence,\n                        buffer.int, buffer.int, buffer.float, buffer.float, buffer.int, buffer.int).also { require(it.valid()) }\n                }\n                PRESENTATION_FEEDBACK -> {\n                    require(buffer.remaining() == 32)\n                    val header = readHeader(buffer)\n                    ControlPacket.PresentationFeedback(\n                        header.leaseSecret,\n                        header.generation,\n                        header.sequence,\n                        buffer.int,\n                        buffer.int,\n                        buffer.int\n                    ).also { require(it.valid()) }\n                }\n                DISCONNECT -> {''')
replace_once(protocol, '''            is ControlPacket.FallbackDeltaReady,\n            is ControlPacket.VideoFeedback,\n            ControlPacket.Disconnect -> null''', '''            is ControlPacket.FallbackDeltaReady,\n            is ControlPacket.VideoFeedback,\n            is ControlPacket.PresentationFeedback,\n            ControlPacket.Disconnect -> null''')
replace_once(protocol, '''        is ControlPacket.VideoFeedback -> VIDEO_FEEDBACK\n        ControlPacket.Disconnect -> DISCONNECT''', '''        is ControlPacket.VideoFeedback -> VIDEO_FEEDBACK\n        is ControlPacket.PresentationFeedback -> PRESENTATION_FEEDBACK\n        ControlPacket.Disconnect -> DISCONNECT''')

# Presentation-aware freshness governor: use real displayed cadence and jump further
# on severe pressure instead of spending multiple 3s epochs draining stale frames.
write(
    "app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt",
    '''package com.aaris.remoteassist.webrtc

/**
 * Bounds capture cost while libwebrtc remains the owner of bitrate, pacing and
 * congestion control. Freshness wins over nominal FPS: a sustainable 30 fps
 * screen is better remote-control UX than a queued/stuttering 60 fps stream.
 */
class VideoCadenceGovernor(private val maxFps: Int) {
    @Volatile
    var cap = maxFps
        private set

    private var pressure = 0
    private var healthy = 0
    private var changedAt = Long.MIN_VALUE / 2

    fun observe(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        requestedFps: Int,
        nowMs: Long
    ): Boolean {
        val sender = outbound.recent ?: return false
        val budgetMs = 1000.0 / requestedFps.coerceAtLeast(1)

        val codecPressure =
            (
                sender.frames >= MIN_MEASURED_FRAMES &&
                    (sender.processingMs ?: 0.0) > budgetMs * CODEC_PRESSURE_BUDGET_RATIO &&
                    sender.fps < requestedFps * FPS_DELIVERY_RATIO
                ) ||
                (
                    receiver != null &&
                        receiver.frames >= MIN_MEASURED_FRAMES &&
                        (receiver.processingMs ?: 0.0) > budgetMs * CODEC_PRESSURE_BUDGET_RATIO &&
                        receiver.fps < minOf(requestedFps.toDouble(), sender.fps) * FPS_DELIVERY_RATIO
                    )

        val loss = outbound.packetLossRatio ?: 0.0
        val receiverDropped = receiver?.dropped?.coerceAtLeast(0) ?: 0
        val receiverSamples = receiver?.let { it.frames.coerceAtLeast(0) + receiverDropped } ?: 0
        val receiverDropRatio = if (receiverSamples > 0) receiverDropped.toDouble() / receiverSamples else 0.0
        val receiverDrops =
            receiverDropped >= MIN_DROPPED_FRAMES_FOR_PRESSURE &&
                receiverSamples >= MIN_RECEIVER_SAMPLES_FOR_DROP_RATIO &&
                receiverDropRatio >= RECEIVER_DROP_PRESSURE_RATIO

        val sendQueueMs = sender.sendQueueMs
        val receiverJitterMs = receiver?.jitterMs
        val queuePressureThresholdMs = maxOf(MIN_QUEUE_PRESSURE_MS, budgetMs * QUEUE_BUDGET_MULTIPLIER)
        val jitterPressureThresholdMs = maxOf(MIN_JITTER_PRESSURE_MS, budgetMs * JITTER_BUDGET_MULTIPLIER)
        val queuePressure = sendQueueMs != null && sendQueueMs > queuePressureThresholdMs
        val receiverDelay =
            receiver != null && receiver.frames >= MIN_MEASURED_FRAMES &&
                receiverJitterMs != null && receiverJitterMs > jitterPressureThresholdMs

        /*
         * RTP/decode counters can look healthy while the controller GPU is
         * visibly hitching. Compare actual EGL swaps against the cadence that
         * made it through sender + decoder, and use long swap gaps as direct
         * motion-to-photon pressure.
         */
        val presentedFrames = receiver?.presentedFrames ?: 0
        val presentedFps = receiver?.presentedFps
        val expectedPresentationFps = if (presentedFps != null) {
            var expected = minOf(requestedFps.toDouble(), sender.fps)
            if (receiver != null && receiver.frames >= MIN_MEASURED_FRAMES) {
                expected = minOf(expected, receiver.fps)
            }
            expected
        } else 0.0
        val presentationRatio =
            if (presentedFps != null && expectedPresentationFps >= MIN_PRESENTATION_EXPECTED_FPS) {
                presentedFps / expectedPresentationFps
            } else 1.0
        val renderGapMs = receiver?.maxRenderGapMs?.toDouble() ?: 0.0
        val renderGapPressureMs = maxOf(MIN_RENDER_GAP_PRESSURE_MS, budgetMs * RENDER_GAP_BUDGET_MULTIPLIER)
        val presentationMeasured =
            presentedFrames >= MIN_PRESENTED_FRAMES && expectedPresentationFps >= MIN_PRESENTATION_EXPECTED_FPS
        val presentationPressure =
            presentationMeasured &&
                (presentationRatio < PRESENTATION_DELIVERY_RATIO || renderGapMs > renderGapPressureMs)

        val congestion =
            loss >= PACKET_LOSS_PRESSURE_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= RTT_PRESSURE_MS ||
                queuePressure || receiverDelay

        val severePresentationPressure =
            presentationMeasured &&
                (presentationRatio < SEVERE_PRESENTATION_DELIVERY_RATIO || renderGapMs >= SEVERE_RENDER_GAP_MS)
        val severePressure =
            loss >= SEVERE_PACKET_LOSS_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= SEVERE_RTT_MS ||
                (sendQueueMs ?: 0.0) >= SEVERE_QUEUE_MS ||
                (receiverJitterMs ?: 0.0) >= SEVERE_JITTER_MS ||
                receiverDropRatio >= SEVERE_RECEIVER_DROP_RATIO ||
                severePresentationPressure

        val overloaded =
            codecPressure || receiverDrops || congestion || presentationPressure ||
                outbound.qualityLimitationReason == "cpu"

        if (overloaded) {
            healthy = 0
            pressure = (pressure + if (severePressure) 2 else 1).coerceAtMost(PRESSURE_SAMPLES_TO_REDUCE)
            val changeInterval = if (severePressure) SEVERE_CHANGE_INTERVAL_MS else MIN_CHANGE_INTERVAL_MS
            if (pressure < PRESSURE_SAMPLES_TO_REDUCE || nowMs - changedAt < changeInterval) return false

            val ceiling = minOf(cap, requestedFps)
            val ordinaryNext = DESCENDING_CAPS.firstOrNull { it < ceiling } ?: return false
            val next = if (severePressure) {
                val delivered = buildList {
                    if (sender.frames >= MIN_MEASURED_FRAMES) add(sender.fps)
                    if (receiver != null && receiver.frames >= MIN_MEASURED_FRAMES) add(receiver.fps)
                    if (presentationMeasured && presentedFps != null) add(presentedFps)
                }.minOrNull()
                val guarded = delivered?.times(SEVERE_OBSERVED_HEADROOM)?.toInt()
                if (guarded == null) ordinaryNext
                else DESCENDING_CAPS.firstOrNull { it < ceiling && it <= guarded } ?: ordinaryNext
            } else ordinaryNext

            cap = next
            changedAt = nowMs
            pressure = 0
            return true
        }

        pressure = 0

        val presentationHealthy =
            !presentationMeasured ||
                (presentationRatio >= HEALTHY_PRESENTATION_RATIO &&
                    renderGapMs < maxOf(HEALTHY_RENDER_GAP_MS, budgetMs * HEALTHY_RENDER_GAP_BUDGET_MULTIPLIER))
        val receiverHealthy =
            if (receiver == null) {
                outbound.qualityLimitationReason == "none" &&
                    outbound.roundTripTimeMs != null && outbound.roundTripTimeMs < HEALTHY_RTT_MS
            } else {
                receiver.frames >= MIN_MEASURED_FRAMES &&
                    receiver.processingMs != null &&
                    receiver.processingMs < budgetMs * CODEC_HEADROOM_BUDGET_RATIO &&
                    (receiver.jitterMs ?: 0.0) < HEALTHY_JITTER_MS &&
                    (receiver.dropped ?: 0) == 0 &&
                    (receiver.freezes ?: 0) == 0 &&
                    presentationHealthy
            }

        val headroom =
            sender.frames >= MIN_MEASURED_FRAMES &&
                sender.processingMs != null && sender.processingMs < budgetMs * CODEC_HEADROOM_BUDGET_RATIO &&
                receiverHealthy && loss < HEALTHY_PACKET_LOSS_RATIO &&
                (sender.sendQueueMs ?: 0.0) < HEALTHY_QUEUE_MS &&
                outbound.qualityLimitationReason != "bandwidth"

        healthy = if (headroom) healthy + 1 else 0
        val healthySamplesRequired = if (receiver == null) LEGACY_HEALTHY_SAMPLES_TO_RAISE else HEALTHY_SAMPLES_TO_RAISE
        if (healthy < healthySamplesRequired || nowMs - changedAt < MIN_RECOVERY_INTERVAL_MS) return false

        val next = ASCENDING_CAPS.firstOrNull { it > cap && it <= maxFps } ?: return false
        cap = next
        changedAt = nowMs
        healthy = 0
        return true
    }

    fun mayReduceResolution(nowMs: Long): Boolean =
        cap <= RESOLUTION_REDUCTION_MAX_FPS && nowMs - changedAt >= RESOLUTION_REDUCTION_GRACE_MS

    private companion object {
        val DESCENDING_CAPS = listOf(60, 30, 24, 20, 15)
        val ASCENDING_CAPS = listOf(15, 20, 24, 30, 60)

        const val MIN_MEASURED_FRAMES = 5
        const val MIN_DROPPED_FRAMES_FOR_PRESSURE = 2
        const val MIN_RECEIVER_SAMPLES_FOR_DROP_RATIO = 8
        const val MIN_PRESENTED_FRAMES = 5
        const val MIN_PRESENTATION_EXPECTED_FPS = 10.0

        const val CODEC_PRESSURE_BUDGET_RATIO = 0.85
        const val CODEC_HEADROOM_BUDGET_RATIO = 0.55
        const val FPS_DELIVERY_RATIO = 0.85

        const val MIN_QUEUE_PRESSURE_MS = 55.0
        const val QUEUE_BUDGET_MULTIPLIER = 2.0
        const val MIN_JITTER_PRESSURE_MS = 85.0
        const val JITTER_BUDGET_MULTIPLIER = 2.5
        const val MIN_RENDER_GAP_PRESSURE_MS = 55.0
        const val RENDER_GAP_BUDGET_MULTIPLIER = 2.5
        const val PRESENTATION_DELIVERY_RATIO = 0.82

        const val PACKET_LOSS_PRESSURE_RATIO = 0.04
        const val RTT_PRESSURE_MS = 650
        const val RECEIVER_DROP_PRESSURE_RATIO = 0.08

        const val SEVERE_PACKET_LOSS_RATIO = 0.12
        const val SEVERE_RTT_MS = 900
        const val SEVERE_QUEUE_MS = 150.0
        const val SEVERE_JITTER_MS = 180.0
        const val SEVERE_RECEIVER_DROP_RATIO = 0.25
        const val SEVERE_PRESENTATION_DELIVERY_RATIO = 0.60
        const val SEVERE_RENDER_GAP_MS = 150.0
        const val SEVERE_OBSERVED_HEADROOM = 1.10

        const val HEALTHY_RTT_MS = 300
        const val HEALTHY_JITTER_MS = 45.0
        const val HEALTHY_QUEUE_MS = 20.0
        const val HEALTHY_PACKET_LOSS_RATIO = 0.025
        const val HEALTHY_PRESENTATION_RATIO = 0.90
        const val HEALTHY_RENDER_GAP_MS = 50.0
        const val HEALTHY_RENDER_GAP_BUDGET_MULTIPLIER = 3.0

        const val PRESSURE_SAMPLES_TO_REDUCE = 2
        const val HEALTHY_SAMPLES_TO_RAISE = 8
        const val LEGACY_HEALTHY_SAMPLES_TO_RAISE = 16
        const val MIN_CHANGE_INTERVAL_MS = 3_000L
        const val SEVERE_CHANGE_INTERVAL_MS = 1_000L
        const val MIN_RECOVERY_INTERVAL_MS = 12_000L

        const val RESOLUTION_REDUCTION_MAX_FPS = 24
        const val RESOLUTION_REDUCTION_GRACE_MS = 6_000L
    }
}
'''
)

# Controller: report real displayed cadence and don't track ACK latency for packets
# the host intentionally never ACKs.
controller = "app/src/main/java/com/aaris/remoteassist/webrtc/ControllerWebRtcSession.kt"
replace_once(
    controller,
    '''    private fun nextCommandSequence(): Long = sequence.incrementAndGet().also {\n        commandLatency.sent(it, SystemClock.elapsedRealtime())\n    }''',
    '''    private fun nextCommandSequence(trackAck: Boolean = true): Long = sequence.incrementAndGet().also {\n        if (trackAck) commandLatency.sent(it, SystemClock.elapsedRealtime())\n    }'''
)
replace_once(
    controller,
    '''                sequence = nextCommandSequence(),\n                streamId = streamId,\n                phase = phase,''',
    '''                sequence = nextCommandSequence(\n                    trackAck = phase != com.aaris.remoteassist.control.GestureStreamPhase.CONTINUE\n                ),\n                streamId = streamId,\n                phase = phase,'''
)
replace_once(
    controller,
    '''    fun setInteractionActive(active: Boolean): Boolean {''',
    '''    fun sendPresentationFeedback(window: PresentationCadenceWindow): Boolean {\n        if (closed.get()) return false\n        val lease = leaseSecret ?: return false\n        val display = geometry ?: return false\n        return peer.sendControl(\n            ControlProtocol.encode(\n                ControlPacket.PresentationFeedback(\n                    leaseSecret = lease,\n                    generation = display.generation,\n                    sequence = feedbackSequence.incrementAndGet(),\n                    intervalMs = window.intervalMs,\n                    renderedFrames = window.renderedFrames,\n                    maxGapMs = window.maxGapMs\n                )\n            )\n        )\n    }\n\n    fun setInteractionActive(active: Boolean): Boolean {'''
)

# UI: measure after real EGL swap, not when RTP/decoder merely produced a frame.
ui = "app/src/main/java/com/aaris/remoteassist/ui/InlineRemoteControllerView.kt"
replace_once(ui, 'import com.aaris.remoteassist.webrtc.RemoteGeometry\n', 'import com.aaris.remoteassist.webrtc.RemoteGeometry\nimport com.aaris.remoteassist.webrtc.PresentationCadenceTracker\n')
replace_once(ui, '''    private val gestureStreamPacer = GestureStreamPacer()\n''', '''    private val gestureStreamPacer = GestureStreamPacer()\n    private val presentationCadence = PresentationCadenceTracker()\n''')
replace_once(ui, '''                        rawFrameSeen.set(false)\n                        renderedFrameSeen.set(false)\n                        frameWidth = 0''', '''                        rawFrameSeen.set(false)\n                        renderedFrameSeen.set(false)\n                        presentationCadence.reset()\n                        frameWidth = 0''')
replace_once(ui, '''                recoveryGeneration.incrementAndGet()\n                renderedFrameSeen.set(false)\n                mainHandler.post {''', '''                recoveryGeneration.incrementAndGet()\n                renderedFrameSeen.set(false)\n                presentationCadence.reset()\n                mainHandler.post {''')
replace_once(ui, '''            renderer.addRenderListener {\n                val generation = recoveryGeneration.get()\n                if (eglRenderer === renderer && renderedFrameSeen.compareAndSet(false, true)) {''', '''            renderer.addRenderListener {\n                val generation = recoveryGeneration.get()\n                presentationCadence\n                    .onPresented(android.os.SystemClock.elapsedRealtime())\n                    ?.let { window ->\n                        mainHandler.post {\n                            if (\n                                attached &&\n                                eglRenderer === renderer &&\n                                generation == recoveryGeneration.get()\n                            ) {\n                                session()?.sendPresentationFeedback(window)\n                            }\n                        }\n                    }\n                if (eglRenderer === renderer && renderedFrameSeen.compareAndSet(false, true)) {''')

# Host accepts only current lease/generation presentation reports through the same
# replay-safe feedback aggregator.
host = "app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt"
replace_once(host, '''            is ControlPacket.VideoFeedback -> displayHandler.post {\n                val current = lease\n                if (!closed.get() && current != null && SessionRuntime.isAuthorized(sessionId, current.leaseSecret, current.displayGeneration)) {\n                    receiverFeedback.accept(packet, current.leaseSecret, current.displayGeneration, android.os.SystemClock.elapsedRealtime())\n                }\n            }\n            is ControlPacket.CommandResult,''', '''            is ControlPacket.VideoFeedback -> displayHandler.post {\n                val current = lease\n                if (!closed.get() && current != null && SessionRuntime.isAuthorized(sessionId, current.leaseSecret, current.displayGeneration)) {\n                    receiverFeedback.accept(packet, current.leaseSecret, current.displayGeneration, android.os.SystemClock.elapsedRealtime())\n                }\n            }\n            is ControlPacket.PresentationFeedback -> displayHandler.post {\n                val current = lease\n                if (!closed.get() && current != null && SessionRuntime.isAuthorized(sessionId, current.leaseSecret, current.displayGeneration)) {\n                    receiverFeedback.accept(packet, current.leaseSecret, current.displayGeneration, android.os.SystemClock.elapsedRealtime())\n                }\n            }\n            is ControlPacket.CommandResult,''')

# ---- AI hands: direct, deterministic app launch as an optional fast path ----
write(
    "app/src/main/java/com/aaris/remoteassist/ai/AiAppMatcher.kt",
    '''package com.aaris.remoteassist.ai

data class AiLaunchCandidate(
    val label: String,
    val packageName: String,
    val activityName: String
)

/** Conservative matching: fast when unambiguous, never fuzzy-click the wrong app. */
object AiAppMatcher {
    fun choose(query: String, candidates: List<AiLaunchCandidate>): AiLaunchCandidate? {
        val raw = query.trim()
        if (raw.isEmpty() || raw.length > 160) return null
        val normalized = normalize(raw)
        if (normalized.isEmpty()) return null
        val queryTokens = normalized.split(' ').filter(String::isNotBlank).toSet()

        val scored = candidates.mapNotNull { candidate ->
            val label = normalize(candidate.label)
            val packageTail = normalize(candidate.packageName.substringAfterLast('.'))
            val score = when {
                candidate.packageName.equals(raw, ignoreCase = true) -> 120
                label == normalized -> 110
                packageTail == normalized -> 100
                label.startsWith("$normalized ") || label.endsWith(" $normalized") -> 90
                queryTokens.size >= 2 && queryTokens.all { it in label.split(' ') } -> 80
                else -> 0
            }
            score.takeIf { it > 0 }?.let { score to candidate }
        }.sortedByDescending { it.first }

        val best = scored.firstOrNull() ?: return null
        val tied = scored.filter { it.first == best.first }
        return when {
            tied.size == 1 -> best.second
            tied.map { it.second.packageName }.distinct().size == 1 -> tied.first().second
            else -> null
        }
    }

    private fun normalize(value: String): String =
        value.lowercase()
            .map { if (it.isLetterOrDigit()) it else ' ' }
            .joinToString("")
            .trim()
            .replace(Regex("\\s+"), " ")
}
'''
)

write(
    "app/src/main/java/com/aaris/remoteassist/ai/AiAppLauncher.kt",
    '''package com.aaris.remoteassist.ai

import android.content.Context
import android.content.Intent

object AiAppLauncher {
    @Suppress("DEPRECATION")
    fun launch(context: Context, query: String): Boolean {
        if (query.isBlank() || query.length > 160) return false
        val packageManager = context.packageManager
        val launcherQuery = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val candidates = packageManager.queryIntentActivities(launcherQuery, 0).mapNotNull { info ->
            val activity = info.activityInfo ?: return@mapNotNull null
            val label = runCatching { info.loadLabel(packageManager)?.toString() }.getOrNull().orEmpty()
            if (label.isBlank()) return@mapNotNull null
            AiLaunchCandidate(label, activity.packageName, activity.name)
        }
        val selected = AiAppMatcher.choose(query, candidates) ?: return false
        val launchIntent = packageManager.getLaunchIntentForPackage(selected.packageName)
            ?: Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setClassName(selected.packageName, selected.activityName)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return runCatching {
            context.startActivity(launchIntent)
            true
        }.getOrDefault(false)
    }
}
'''
)

manifest = "app/src/main/AndroidManifest.xml"
replace_once(manifest, '''    <uses-permission android:name="android.permission.VIBRATE" />\n\n    <application''', '''    <uses-permission android:name="android.permission.VIBRATE" />\n\n    <queries>\n        <intent>\n            <action android:name="android.intent.action.MAIN" />\n            <category android:name="android.intent.category.LAUNCHER" />\n        </intent>\n    </queries>\n\n    <application''')

engine = "app/src/main/java/com/aaris/remoteassist/ai/AiObservationEngine.kt"
replace_once(engine, '        val navigation = action in setOf("home", "back", "recents")', '        val navigation = action in setOf("home", "back", "recents", "open_app")')
replace_once(engine, '        if (action != "home" && !sameWindow(observed, ui)) return refused("FOREGROUND_CHANGED")', '        if (action !in setOf("home", "open_app") && !sameWindow(observed, ui)) return refused("FOREGROUND_CHANGED")')
replace_once(engine, '                (action == "home" || sameWindow(ui, current)) &&', '                (action in setOf("home", "open_app") || sameWindow(ui, current)) &&')

service = "app/src/main/java/com/aaris/remoteassist/ai/AiConnectorService.kt"
replace_once(service, '''                        val currentLease = lease ?: return@withTimeout failure("NOT_CONNECTED")\n                        val (width, height) = engine.geometry()\n                        val command = AiActionTranslator.translate(args, currentLease, ++sequence, width, height)\n                        engine.ledger.consume() // Even a refused/no-op action consumes its observation.\n                        outcomes[id] = failure("OUTCOME_UNKNOWN", null)\n                        dispatched = true; applied = null\n                        val done = CompletableDeferred<Boolean>()\n                        val expiresAt = SystemClock.elapsedRealtime() + 1500\n                        AssistAccessibilityService.dispatch(command, precondition = {\n                            !stopping && socket === ws && validation.stillValid() &&\n                                SystemClock.elapsedRealtime() <= expiresAt &&\n                                CaptureProfile.current(this@AiConnectorService, CaptureTier.BALANCED).let {\n                                    it.displayWidthPx == width && it.displayHeightPx == height\n                                }\n                        }) { done.complete(it) }\n                        applied = withTimeout(3500) { done.await() }''', '''                        val currentLease = lease ?: return@withTimeout failure("NOT_CONNECTED")\n                        val (width, height) = engine.geometry()\n                        val action = args.getString("action")\n                        engine.ledger.consume() // Even a refused/no-op action consumes its observation.\n                        outcomes[id] = failure("OUTCOME_UNKNOWN", null)\n                        dispatched = true; applied = null\n                        val expiresAt = SystemClock.elapsedRealtime() + 1500\n                        val preconditionValid = {\n                            !stopping && socket === ws && validation.stillValid() &&\n                                SystemClock.elapsedRealtime() <= expiresAt &&\n                                SessionRuntime.isAuthorized(\n                                    currentLease.sessionId,\n                                    currentLease.leaseSecret,\n                                    currentLease.displayGeneration\n                                ) &&\n                                CaptureProfile.current(this@AiConnectorService, CaptureTier.BALANCED).let {\n                                    it.displayWidthPx == width && it.displayHeightPx == height\n                                }\n                        }\n                        applied = if (action == "open_app") {\n                            preconditionValid() && AiAppLauncher.launch(\n                                this@AiConnectorService,\n                                args.getString("app")\n                            )\n                        } else {\n                            val command = AiActionTranslator.translate(\n                                args,\n                                currentLease,\n                                ++sequence,\n                                width,\n                                height\n                            )\n                            val done = CompletableDeferred<Boolean>()\n                            AssistAccessibilityService.dispatch(\n                                command,\n                                precondition = preconditionValid\n                            ) { done.complete(it) }\n                            withTimeout(3500) { done.await() }\n                        }''')

mcp = "cloudflare/mcp-worker.js"
replace_once(mcp, "action: { type: 'string', enum: ['tap', 'long_press', 'swipe', 'type', 'back', 'home', 'recents'] },", "action: { type: 'string', enum: ['tap', 'long_press', 'swipe', 'type', 'back', 'home', 'recents', 'open_app'] },")
replace_once(mcp, "      text: { type: 'string', minLength: 1, maxLength: 1000 }", "      text: { type: 'string', minLength: 1, maxLength: 1000 },\n      app: { type: 'string', minLength: 1, maxLength: 160 }")
replace_once(mcp, "tap/long_press validate the target, swipe validates its path, and type validates the focused field.", "tap/long_press validate the target, swipe validates its path, type validates the focused field, and open_app can directly launch an unambiguous installed launcher app by label or package.")
replace_once(mcp, '''  if (a.text !== undefined && (typeof a.text !== 'string' || !a.text.length || a.text.length > 1000 || new TextEncoder().encode(a.text).length > 2048)) return false;\n  return a.action !== 'type' || typeof a.text === 'string';''', '''  if (a.text !== undefined && (typeof a.text !== 'string' || !a.text.length || a.text.length > 1000 || new TextEncoder().encode(a.text).length > 2048)) return false;\n  if (a.app !== undefined && (typeof a.app !== 'string' || !a.app.trim().length || a.app.length > 160 || new TextEncoder().encode(a.app).length > 512)) return false;\n  if (a.action === 'type') return typeof a.text === 'string';\n  if (a.action === 'open_app') return typeof a.app === 'string';\n  return true;''')

# ---- regression tests ----
write(
    "app/src/test/java/com/aaris/remoteassist/webrtc/PresentationFeedbackTest.kt",
    '''package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import org.junit.Assert.*
import org.junit.Test

class PresentationFeedbackTest {
    @Test fun trackerMeasuresActualSwapCadenceAndLargestGap() {
        val tracker = PresentationCadenceTracker(minWindowMs = 500)
        assertNull(tracker.onPresented(1_000))
        var sample: PresentationCadenceWindow? = null
        for (time in listOf(1_016L, 1_032L, 1_048L, 1_080L, 1_096L, 1_200L, 1_300L, 1_400L, 1_500L)) {
            sample = tracker.onPresented(time) ?: sample
        }
        val result = checkNotNull(sample)
        assertEquals(500, result.intervalMs)
        assertEquals(10, result.renderedFrames)
        assertEquals(104, result.maxGapMs)
    }

    @Test fun backwardsOrVeryStaleClockResetsInsteadOfInventingJank() {
        val tracker = PresentationCadenceTracker(minWindowMs = 500)
        tracker.onPresented(1_000)
        tracker.onPresented(1_100)
        assertNull(tracker.onPresented(900))
        assertNull(tracker.onPresented(8_000))
    }

    @Test fun presentationPacketRoundTripsAndRejectsMalformedWindows() {
        val packet = ControlPacket.PresentationFeedback(42, 3, 7, 1000, 55, 41)
        val bytes = ControlProtocol.encode(packet)
        assertEquals(34, bytes.size)
        assertEquals(packet, ControlProtocol.decode(bytes))
        assertNull(ControlProtocol.toRemoteCommand("session", packet, 1080, 2400))
        assertNull(ControlProtocol.decode(bytes.copyOf(bytes.size - 1)))
        assertThrows(IllegalArgumentException::class.java) {
            ControlProtocol.encode(packet.copy(renderedFrames = 0))
        }
    }

    @Test fun leaseBoundAggregatorMergesDecoderAndActualPresentationWindows() {
        val feedback = ReceiverVideoFeedback()
        val video = ControlPacket.VideoFeedback(42, 2, 1, 1000, 60, 5f, 12f, 0, 0)
        val display = ControlPacket.PresentationFeedback(42, 2, 1, 1000, 38, 72)
        assertTrue(feedback.accept(video, 42, 2, 100))
        assertTrue(feedback.accept(display, 42, 2, 120))
        val merged = checkNotNull(feedback.consume(42, 2, 200))
        assertEquals(60, merged.frames)
        assertEquals(38, merged.presentedFrames)
        assertEquals(38.0, merged.presentedFps!!, 0.001)
        assertEquals(72, merged.maxRenderGapMs)
        assertNull(feedback.consume(42, 2, 201))
        assertFalse(feedback.accept(display, 42, 3, 300))
    }
}
'''
)

write(
    "app/src/test/java/com/aaris/remoteassist/ai/AiAppMatcherTest.kt",
    '''package com.aaris.remoteassist.ai

import org.junit.Assert.*
import org.junit.Test

class AiAppMatcherTest {
    private val apps = listOf(
        AiLaunchCandidate("ChatGPT", "com.openai.chatgpt", "Main"),
        AiLaunchCandidate("Google Chrome", "com.android.chrome", "Main"),
        AiLaunchCandidate("Chrome Beta", "com.chrome.beta", "Main"),
        AiLaunchCandidate("Camera", "com.vendor.camera", "Camera")
    )

    @Test fun exactLabelAndPackageAreDeterministic() {
        assertEquals("com.openai.chatgpt", AiAppMatcher.choose("chatgpt", apps)?.packageName)
        assertEquals("com.android.chrome", AiAppMatcher.choose("com.android.chrome", apps)?.packageName)
    }

    @Test fun uniqueShortLabelMaySelectLongerLauncherName() {
        assertEquals("com.android.chrome", AiAppMatcher.choose("google chrome", apps)?.packageName)
    }

    @Test fun ambiguousOrUnrelatedNamesFailClosed() {
        val ambiguous = listOf(
            AiLaunchCandidate("Files Alpha", "a.files", "Main"),
            AiLaunchCandidate("Files Beta", "b.files", "Main")
        )
        assertNull(AiAppMatcher.choose("files", ambiguous))
        assertNull(AiAppMatcher.choose("bank", apps))
        assertNull(AiAppMatcher.choose("   ", apps))
    }
}
'''
)

# Add presentation-driven cadence coverage to the existing video test.
video_test = "app/src/test/java/com/aaris/remoteassist/webrtc/VideoFeedbackTest.kt"
replace_once(video_test, '''    @Test fun isolatedSpikeAndQuietOrMissingFramesDoNotDriveQualityOscillation() {''', '''    @Test fun severeControllerPresentationJankCanJumpDirectlyToSustainableCadence() {\n        val governor = VideoCadenceGovernor(60)\n        val sending60 = outbound().let { it.copy(recent = it.recent!!.copy(frames = 60)) }\n        val displayBound = receiver().copy(\n            frames = 60,\n            presentationIntervalMs = 1000,\n            presentedFrames = 22,\n            maxRenderGapMs = 190\n        )\n        assertTrue(governor.observe(sending60, displayBound, 60, 1000))\n        assertEquals(24, governor.cap)\n    }\n\n    @Test fun healthyRealPresentationDoesNotPunishPipelinedSixtyFps() {\n        val governor = VideoCadenceGovernor(60)\n        val sending60 = outbound(25.0).let { it.copy(recent = it.recent!!.copy(frames = 60)) }\n        val displayed60 = receiver(25.0).copy(\n            frames = 60,\n            presentationIntervalMs = 1000,\n            presentedFrames = 59,\n            maxRenderGapMs = 22\n        )\n        repeat(10) { governor.observe(sending60, displayed60, 60, 1000L + it * 1000) }\n        assertEquals(60, governor.cap)\n    }\n\n    @Test fun isolatedSpikeAndQuietOrMissingFramesDoNotDriveQualityOscillation() {''')

mcp_test = "cloudflare/mcp-worker.test.mjs"
replace_once(mcp_test, '''  assert.ok(validateArguments('phone_action', { ...args, action: 'type', text: 'Hello' }));\n  assert.equal(validateArguments('phone_observe', { quality: 'invalid' }), false);''', '''  assert.ok(validateArguments('phone_action', { ...args, action: 'type', text: 'Hello' }));\n  assert.ok(validateArguments('phone_action', { ...args, action: 'open_app', app: 'ChatGPT' }));\n  assert.equal(validateArguments('phone_action', { ...args, action: 'open_app' }), false);\n  assert.equal(validateArguments('phone_action', { ...args, action: 'open_app', app: '   ' }), false);\n  assert.equal(validateArguments('phone_observe', { quality: 'invalid' }), false);''')

write(
    "docs/RTC_AND_AI_195.md",
    '''# Aaris Remote 1.9.5 — presentation-aware realtime + faster AI hands

## End-to-end architecture

Human control path:

`controller touch -> control-live-v1/control-v1 -> host Accessibility -> MediaProjection -> WebRTC encoder -> direct ICE/TURN -> controller decoder -> EglRenderer -> TextureView`

Cloudflare `aaris-remote-ice` remains the signaling/TURN-credential control plane. It does **not** proxy steady-state screen video, so no placebo Worker placement/CPU change is used to claim lower video latency.

AI path:

`phone_observe -> target validation -> one action -> fresh observation`

The existing one-action safety contract remains intact.

## Realtime upgrades

- The controller now reports **actual EGL presentation cadence** (real displayed swaps), not only RTP/decoder counters.
- The host merges decoder + presentation feedback only for the current lease/display generation and rejects replayed sequences.
- The cadence governor now sees controller-side render starvation and long frame gaps. When severe pressure is measured, it may jump directly from 60 fps to a sustainable lower rung instead of spending several 3-second epochs accumulating stale frames.
- Recovery remains deliberately slower than degradation to avoid oscillation.
- Live gesture `CONTINUE` packets are no longer inserted into the command-ACK latency tracker because the host intentionally never ACKs them. This prevents long drags from evicting useful authoritative ACK samples.

## AI hand upgrade

`phone_action` gains optional `open_app` with an `app` label/package argument. Android resolves only launcher-visible installed apps and uses conservative deterministic matching. Ambiguous names fail closed, so the AI can fall back to the existing Home/Search/tap flow instead of opening a guessed app.

The action still requires a fresh observation ticket, the active AI lease, unchanged display geometry, and the existing explicit foreground screen-sharing session.

## Regression coverage

- Presentation window timing/max-gap tracking.
- Presentation packet wire round-trip and malformed-packet rejection.
- Lease/generation/replay-safe merge of decoder and presentation feedback.
- Direct severe-presentation-jank cadence reduction and healthy 60 fps stability.
- Conservative app-label/package matching.
- MCP schema validation for `open_app`.
'''
)

print("v1.9.5 patch applied successfully")
