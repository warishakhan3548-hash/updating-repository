package com.aaris.remoteassist.webrtc

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
