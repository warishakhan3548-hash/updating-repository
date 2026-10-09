package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket

private data class PhotonTimingWindow(
    val inputToGlassUpperBoundMs: Int,
    val commandAckMs: Int,
    val postAckPresentMs: Int
)

/**
 * Lease-bound receiver feedback.
 *
 * Decoder/stat windows remain one-use. The most recent measured EGL cadence
 * may be retained for a short bounded interval solely to bridge independent
 * render/getStats clock phases; sequence + fresh/held metadata prevents that
 * retained sample from tuning video twice. Old generations and replayed packets
 * still cannot tune video.
 */
class ReceiverVideoFeedback {
    private var identity: Pair<Long, Int>? = null
    private var lastSequence = 0L
    private var receivedAt = 0L
    private var pending: VideoHealthWindow? = null
    private var lastDecodedAtMs: Long? = null

    private var lastPresentationSequence = 0L
    private var lastPresentationHeartbeatSequence = 0L
    private var presentationReceivedAt = 0L
    private var lastPresentedAtMs: Long? = null
    private var pendingPresentation: PresentationCadenceWindow? = null
    private var retainedPresentation: PresentationCadenceWindow? = null
    private var retainedPresentationAtMs = 0L
    private var retainedPresentationSequence = 0L
    private var lastRecoveryPresentationSequence = 0L
    private var lastCapabilitiesSequence = 0L
    private var capabilitiesAtMs = 0L
    private var displayRefreshRateHz: Double? = null

    private var lastPhotonSequence = 0L
    private var photonReceivedAtMs = 0L
    private var pendingPhoton: PhotonTimingWindow? = null
    private var retainedPhoton: PhotonTimingWindow? = null
    private var retainedPhotonAtMs = 0L
    private var retainedPhotonSequence = 0L

    private fun bindIdentity(secret: Long, generation: Int) {
        val key = secret to generation
        if (identity == key) return
        identity = key
        lastSequence = 0L
        receivedAt = 0L
        pending = null
        lastDecodedAtMs = null
        lastPresentationSequence = 0L
        lastPresentationHeartbeatSequence = 0L
        presentationReceivedAt = 0L
        lastPresentedAtMs = null
        pendingPresentation = null
        retainedPresentation = null
        retainedPresentationAtMs = 0L
        retainedPresentationSequence = 0L
        lastRecoveryPresentationSequence = 0L
        lastCapabilitiesSequence = 0L
        capabilitiesAtMs = 0L
        displayRefreshRateHz = null
        lastPhotonSequence = 0L
        photonReceivedAtMs = 0L
        pendingPhoton = null
        retainedPhoton = null
        retainedPhotonAtMs = 0L
        retainedPhotonSequence = 0L
    }

    fun accept(packet: ControlPacket.DisplayCapabilities, secret: Long, generation: Int, nowMs: Long): Boolean {
        if (!packet.valid() || packet.leaseSecret != secret || packet.generation != generation) return false
        bindIdentity(secret, generation)
        if (packet.sequence <= lastCapabilitiesSequence) return false
        lastCapabilitiesSequence = packet.sequence
        capabilitiesAtMs = nowMs
        displayRefreshRateHz = packet.refreshRateHz.toDouble()
        return true
    }

    fun accept(
        packet: ControlPacket.PhotonFeedback,
        secret: Long,
        generation: Int,
        nowMs: Long
    ): Boolean {
        if (
            !packet.valid() ||
            packet.leaseSecret != secret ||
            packet.generation != generation
        ) {
            return false
        }
        bindIdentity(secret, generation)
        if (packet.sequence <= lastPhotonSequence) return false
        lastPhotonSequence = packet.sequence
        photonReceivedAtMs = nowMs
        pendingPhoton =
            PhotonTimingWindow(
                inputToGlassUpperBoundMs =
                    packet.inputToGlassUpperBoundMs,
                commandAckMs = packet.commandAckMs,
                postAckPresentMs = packet.postAckPresentMs
            )
        return true
    }

    fun accept(packet: ControlPacket.VideoFeedback, secret: Long, generation: Int, nowMs: Long): Boolean {
        if (!packet.valid() || packet.leaseSecret != secret || packet.generation != generation) return false
        bindIdentity(secret, generation)
        if (packet.sequence <= lastSequence) return false
        lastSequence = packet.sequence
        if (packet.decodedFrames > 0) lastDecodedAtMs = nowMs
        val incoming = VideoHealthWindow(
            packet.intervalMs,
            packet.decodedFrames,
            packet.decodeMs.takeIf { it >= 0 }?.toDouble(),
            packet.jitterMs.takeIf { it >= 0 }?.toDouble(),
            packet.droppedFrames.takeIf { it >= 0 },
            packet.freezeEvents.takeIf { it >= 0 }
        )
        /*
         * Controller decoder statistics and host outbound getStats() are not
         * phase-locked. Last-writer-wins could erase a freeze, a dropped-frame
         * burst or low decoded cadence when two receiver reports arrived before
         * the host consumed its next outbound sample.
         *
         * Combine ONLY consecutive, fresh reports for this lease. Do not add
         * buffering to the media path: this is a small control-plane window.
         */
        /*
         * VideoFeedback is best-effort telemetry, not a gap-free log. If a
         * report was lost (or its callback stalled), two 500 ms decoder
         * windows must not be added as though they covered the intervening
         * wall-clock time. That fabricates a healthy FPS and can hide the
         * exact decoder freeze the host needs to react to.
         *
         * As with EGL feedback, bound the arrival gap against the INCOMING
         * interval, not the accumulated pending interval. Allow transport
         * and scheduler jitter, but never join disconnected decoder islands.
         * This changes only control-plane accounting; no RTP buffer, encoder
         * or new getStats() request is added.
         */
        val previous = pending?.takeIf {
            val reportGapMs = nowMs - receivedAt
            reportGapMs in 0L..minOf(
                MAX_AGE_MS,
                incoming.intervalMs.toLong() +
                    VIDEO_REPORT_JITTER_TOLERANCE_MS
            )
        }
        pending = previous?.let { combineVideoWindows(it, incoming) } ?: incoming
        receivedAt = nowMs
        return true
    }

    private fun combineVideoWindows(
        previous: VideoHealthWindow,
        incoming: VideoHealthWindow
    ): VideoHealthWindow {
        val interval = previous.intervalMs + incoming.intervalMs
        val frames = previous.frames + incoming.frames
        if (
            interval > MAX_PRESENTATION_INTERVAL_MS ||
            frames > MAX_PRESENTED_FRAMES
        ) {
            // The bounds are the same as a single controller feedback window.
            // Start clean rather than report truncated or invented averages.
            return incoming
        }

        fun frameWeighted(before: Double?, after: Double?): Double? {
            if (before == null || after == null || frames == 0) return null
            return (
                (before * previous.frames + after * incoming.frames) / frames
            ).takeIf { it.isFinite() }
        }

        fun sumKnown(before: Int?, after: Int?): Int? =
            if (before == null || after == null) null else
                (before + after).takeIf { it <= MAX_PRESENTED_FRAMES }

        return VideoHealthWindow(
            intervalMs = interval,
            frames = frames,
            processingMs = frameWeighted(previous.processingMs, incoming.processingMs),
            jitterMs = frameWeighted(previous.jitterMs, incoming.jitterMs),
            dropped = sumKnown(previous.dropped, incoming.dropped),
            freezes = sumKnown(previous.freezes, incoming.freezes)
        )
    }

    /** Consuming a tuning window must not erase evidence of a working decoder. */
    fun hasRecentDecodedFrames(secret: Long, generation: Int, nowMs: Long): Boolean =
        identity == secret to generation &&
            lastDecodedAtMs?.let { nowMs - it in 0L..MAX_AGE_MS } == true

    fun accept(packet: ControlPacket.PresentationFeedback, secret: Long, generation: Int, nowMs: Long): Boolean {
        if (!packet.valid() || packet.leaseSecret != secret || packet.generation != generation) return false
        bindIdentity(secret, generation)
        if (packet.sequence <= lastPresentationSequence) return false
        lastPresentationSequence = packet.sequence

        val incoming = PresentationCadenceWindow(
            intervalMs = packet.intervalMs,
            renderedFrames = packet.renderedFrames,
            maxGapMs = packet.maxGapMs
        )

        /*
         * EGL presentation feedback intentionally arrives more often than the
         * sender's expensive getStats() probe. Accumulate consecutive windows
         * until the host consumes them so an early half-second hitch cannot be
         * overwritten by a later healthy half-second just before the stats tick.
         *
         * FPS remains an aggregate renderedFrames / interval measurement, while
         * maxGap keeps the worst motion-to-photon stall seen in the interval.
         * If a consumer disappears long enough to exceed protocol bounds, start
         * a fresh bounded window rather than manufacturing an oversized packet.
         */
        /*
         * Presentation packets travel on an unordered, non-retransmitted
         * telemetry lane. If an interval is lost or the viewer was paused,
         * the next packet must not silently bridge that missing wall-clock
         * time. The packet's interval covers only its own measured swaps.
         *
         * Allow bounded arrival jitter around the *incoming* interval,
         * not the accumulated interval (which grows while host stats are
         * asynchronous). An old bad sample must not contaminate a new one;
         * two healthy islands must not be mistaken for continuous playback.
         */
        val previous = pendingPresentation?.takeIf {
            val reportGapMs = nowMs - presentationReceivedAt
            reportGapMs in 0L..minOf(
                MAX_AGE_MS,
                incoming.intervalMs.toLong() +
                    PRESENTATION_REPORT_JITTER_TOLERANCE_MS
            )
        }
        pendingPresentation = previous?.let { previous ->
            val combinedInterval = previous.intervalMs + incoming.intervalMs
            val combinedFrames = previous.renderedFrames + incoming.renderedFrames
            if (
                combinedInterval <= MAX_PRESENTATION_INTERVAL_MS &&
                combinedFrames <= MAX_PRESENTED_FRAMES
            ) {
                PresentationCadenceWindow(
                    intervalMs = combinedInterval,
                    renderedFrames = combinedFrames,
                    maxGapMs = maxOf(previous.maxGapMs, incoming.maxGapMs)
                )
            } else {
                incoming
            }
        } ?: incoming
        presentationReceivedAt = nowMs
        lastPresentedAtMs = nowMs
        return true
    }

    fun accept(
        packet: ControlPacket.PresentationHeartbeat,
        secret: Long,
        generation: Int,
        nowMs: Long
    ): Boolean {
        if (!packet.valid() || packet.leaseSecret != secret || packet.generation != generation) return false
        bindIdentity(secret, generation)
        if (packet.sequence <= lastPresentationHeartbeatSequence) return false
        lastPresentationHeartbeatSequence = packet.sequence
        lastPresentedAtMs = nowMs
        return true
    }

    /**
     * Only take one-use receiver measurements when the sender has completed a
     * real >=500 ms stats window. An early startup/reconfiguration getStats()
     * callback has no outbound interval to pair with this evidence; draining it
     * there would silently discard decoder stalls and EGL gaps before the
     * adaptation governors could use them.
     *
     * Keep pending reports bounded by their existing age limits. This is
     * control-plane retention only; no video frames are buffered here.
     */
    fun consume(
        secret: Long,
        generation: Int,
        nowMs: Long,
        senderWindowReady: Boolean = true
    ): VideoHealthWindow? {
        if (!senderWindowReady) return null
        if (identity != secret to generation) return null

        val video = pending?.takeIf { nowMs - receivedAt in 0..MAX_AGE_MS }
        pending = null

        /*
         * Render feedback and getStats() both run around 500 ms but are not
         * phase-locked. Clearing the cadence sample after one consume made the
         * next stats tick frequently see present=null/gap=null even though EGL
         * was swapping normally. Retain the latest measured cadence briefly so
         * every stats phase can observe it.
         *
         * The fresh flag + sequence prevent governors from counting the same
         * retained sample twice as new proof or repeated pressure.
         */
        val newlyConsumedPresentation =
            pendingPresentation?.takeIf {
                nowMs - presentationReceivedAt in 0..MAX_AGE_MS
            }
        pendingPresentation = null

        if (newlyConsumedPresentation != null) {
            retainedPresentation = newlyConsumedPresentation
            retainedPresentationAtMs = presentationReceivedAt
            retainedPresentationSequence = lastPresentationSequence
        }

        val presentation =
            newlyConsumedPresentation
                ?: retainedPresentation?.takeIf {
                    nowMs - retainedPresentationAtMs in
                        0L..MAX_RETAINED_PRESENTATION_AGE_MS
                }
        val presentationIsFresh = newlyConsumedPresentation != null
        val presentationSampleAgeMs =
            presentation?.let {
                (nowMs - retainedPresentationAtMs)
                    .takeIf { age ->
                        age in 0L..MAX_RETAINED_PRESENTATION_AGE_MS
                    }
                    ?.toInt()
            }
        val presentationSampleSequence =
            presentation?.let { retainedPresentationSequence.takeIf { it > 0L } }

        // An EGL window can arrive on an earlier host tick than its decoder
        // report. Pair its bounded, unused proof once; do not replay its
        // presentationSampleFresh pressure event or the decoder counters.
        val recoveryPresentationIsFresh =
            video != null &&
                presentationSampleAgeMs?.let { it in 0..MAX_RECOVERY_PRESENTATION_AGE_MS } == true &&
                presentationSampleSequence?.let { it > lastRecoveryPresentationSequence } == true
        if (recoveryPresentationIsFresh) {
            lastRecoveryPresentationSequence = checkNotNull(presentationSampleSequence)
        }

        val presentationAgeMs = lastPresentedAtMs
            ?.let { nowMs - it }
            ?.takeIf { it in 0L..MAX_PRESENTATION_LIVENESS_AGE_MS }
            ?.toInt()

        val newlyConsumedPhoton =
            pendingPhoton?.takeIf {
                nowMs - photonReceivedAtMs in 0L..MAX_AGE_MS
            }
        pendingPhoton = null
        if (newlyConsumedPhoton != null) {
            retainedPhoton = newlyConsumedPhoton
            retainedPhotonAtMs = photonReceivedAtMs
            retainedPhotonSequence = lastPhotonSequence
        }
        val photon =
            newlyConsumedPhoton
                ?: retainedPhoton?.takeIf {
                    nowMs - retainedPhotonAtMs in
                        0L..MAX_RETAINED_PHOTON_AGE_MS
                }
        val photonIsFresh = newlyConsumedPhoton != null
        val photonSampleAgeMs =
            photon?.let {
                (nowMs - retainedPhotonAtMs)
                    .takeIf { age ->
                        age in 0L..MAX_RETAINED_PHOTON_AGE_MS
                    }
                    ?.toInt()
            }
        val photonSampleSequence =
            photon?.let {
                retainedPhotonSequence.takeIf { it > 0L }
            }

        if (
            video == null &&
            presentation == null &&
            presentationAgeMs == null &&
            photon == null
        ) {
            return null
        }

        val base = video ?: VideoHealthWindow(
            intervalMs = presentation?.intervalMs ?: 1_000,
            frames = 0,
            processingMs = null,
            jitterMs = null,
            dropped = null,
            freezes = null,
            presentationAgeMs = presentationAgeMs,
            hasDecoderSample = false
        )
        val refreshRate =
            displayRefreshRateHz?.takeIf {
                nowMs - capabilitiesAtMs in 0L..MAX_CAPABILITIES_AGE_MS
            }
        var result =
            if (presentation == null) {
                base.copy(
                    presentationAgeMs = presentationAgeMs,
                    displayRefreshRateHz = refreshRate
                )
            } else {
                base.copy(
                    presentationIntervalMs = presentation.intervalMs,
                    presentedFrames = presentation.renderedFrames,
                    maxRenderGapMs = presentation.maxGapMs,
                    presentationAgeMs = presentationAgeMs,
                    displayRefreshRateHz = refreshRate,
                    presentationSampleSequence = presentationSampleSequence,
                    presentationSampleAgeMs = presentationSampleAgeMs,
                    presentationSampleFresh = presentationIsFresh,
                    presentationRecoverySampleFresh = recoveryPresentationIsFresh
                )
            }

        if (photon != null) {
            result =
                result.copy(
                    inputToGlassUpperBoundMs =
                        photon.inputToGlassUpperBoundMs,
                    commandAckMs = photon.commandAckMs,
                    postAckPresentMs = photon.postAckPresentMs,
                    photonSampleSequence = photonSampleSequence,
                    photonSampleAgeMs = photonSampleAgeMs,
                    photonSampleFresh = photonIsFresh
                )
        }
        return result.copy(
            decoderSampleAgeMs = if (lastSequence > 0L) {
                (nowMs - receivedAt).takeIf { it in 0L..MAX_AGE_MS }?.toInt()
            } else null
        )
    }

    private companion object {
        const val MAX_AGE_MS = 3_000L
        // Network callback jitter tolerance, not media buffer or hold time.
        const val PRESENTATION_REPORT_JITTER_TOLERANCE_MS = 750L
        // Permit delayed decoder reports without claiming a missing window ran.
        const val VIDEO_REPORT_JITTER_TOLERANCE_MS = 750L
        const val MAX_CAPABILITIES_AGE_MS = 15_000L
        // Long enough to bridge independent 500 ms stats/render phases, short
        // enough that high-cadence promotion still requires current glass proof.
        const val MAX_RETAINED_PRESENTATION_AGE_MS = 1_500L
        const val MAX_RECOVERY_PRESENTATION_AGE_MS = 1_000
        const val MAX_RETAINED_PHOTON_AGE_MS = 3_000L
        const val MAX_PRESENTATION_INTERVAL_MS = 6_000
        const val MAX_PRESENTED_FRAMES = 2_048
        const val MAX_PRESENTATION_LIVENESS_AGE_MS = 30_000L
    }
}
