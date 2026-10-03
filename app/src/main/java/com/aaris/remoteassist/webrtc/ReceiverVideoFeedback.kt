package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket

/** One-use, lease-bound feedback. Old generations and buffered/replayed reports cannot tune video. */
class ReceiverVideoFeedback {
    private var identity: Pair<Long, Int>? = null
    private var lastSequence = 0L
    private var receivedAt = 0L
    private var pending: VideoHealthWindow? = null

    fun accept(packet: ControlPacket.VideoFeedback, secret: Long, generation: Int, nowMs: Long): Boolean {
        if (!packet.valid() || packet.leaseSecret != secret || packet.generation != generation) return false
        val key = secret to generation
        if (identity != key) { identity = key; lastSequence = 0; pending = null }
        if (packet.sequence <= lastSequence) return false
        lastSequence = packet.sequence; receivedAt = nowMs
        pending = VideoHealthWindow(packet.intervalMs, packet.decodedFrames,
            packet.decodeMs.takeIf { it >= 0 }?.toDouble(), packet.jitterMs.takeIf { it >= 0 }?.toDouble(),
            packet.droppedFrames.takeIf { it >= 0 }, packet.freezeEvents.takeIf { it >= 0 })
        return true
    }

    fun consume(secret: Long, generation: Int, nowMs: Long): VideoHealthWindow? {
        val result = pending; pending = null
        return result?.takeIf { identity == secret to generation && nowMs - receivedAt in 0..3000 }
    }
}
