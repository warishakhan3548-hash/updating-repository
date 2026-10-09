package com.aaris.remoteassist.webrtc

import kotlin.math.roundToInt

internal enum class PhotonFreshnessState {
    UNKNOWN,
    CLEAN,
    WATCH,
    PRESSURE
}

internal data class PhotonPolicy(
    val state: PhotonFreshnessState,
    val allowCadencePromotion: Boolean,
    val allowResolutionRecovery: Boolean,
    val glassDeliveryRatio: Double?,
    val pipelineDebtMs: Double?,
    val inputToGlassUpperBoundMs: Int?,
    val commandAckMs: Int?,
    val postAckPresentMs: Int?,
    val cleanGlassWindows: Int
) {
    fun compact(): String {
        fun ratio(value: Double?): String =
            value
                ?.takeIf { it.isFinite() && it >= 0.0 }
                ?.let { "${(it * 100.0).roundToInt()}%" }
                ?: "-"
        fun ms(value: Double?): String =
            value
                ?.takeIf { it.isFinite() && it >= 0.0 }
                ?.roundToInt()
                ?.let { "${it}ms" }
                ?: "-"
        fun ms(value: Int?): String =
            value?.takeIf { it >= 0 }?.let { "${it}ms" } ?: "-"

        return "photon=${state.name.lowercase()} " +
            "glass=${ratio(glassDeliveryRatio)} " +
            "debt=${ms(pipelineDebtMs)} " +
            "ackSwapProxy=${ms(inputToGlassUpperBoundMs)} " +
            "ack=${ms(commandAckMs)} " +
            "postAck=${ms(postAckPresentMs)} " +
            "clean=$cleanGlassWindows " +
            "promote=$allowCadencePromotion detail=$allowResolutionRecovery"
    }
}

/**
 * Master freshness gate above the existing pixel and cadence governors.
 *
 * This class deliberately does not set bitrate, resolution or FPS directly.
 * Libwebrtc remains responsible for congestion control; MotionVideoBudget owns
 * pixel relief and VideoCadenceGovernor owns temporal relief. PhotonFreshness-
 * Governor coordinates only the *upward* direction so those actuators cannot
 * race each other and grow quality while end-to-end freshness is unproven.
 *
 * The legacy inputToGlassUpperBoundMs field is an ACK-to-next-swap proxy, not
 * proof that a particular input appeared in the displayed frame. A high ACK
 * alone is not media pressure. The post-ACK swap gap can block promotion but a
 * low value cannot establish low input-to-photon latency through a buffer.
 */
internal class PhotonFreshnessGovernor {
    private var cleanGlassWindows = 0
    private var lastObserveAtMs = Long.MIN_VALUE / 2
    private var lastPolicy =
        PhotonPolicy(
            state = PhotonFreshnessState.UNKNOWN,
            allowCadencePromotion = false,
            allowResolutionRecovery = false,
            glassDeliveryRatio = null,
            pipelineDebtMs = null,
            inputToGlassUpperBoundMs = null,
            commandAckMs = null,
            postAckPresentMs = null,
            cleanGlassWindows = 0
        )

    fun observe(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        targetFps: Int,
        interactionActive: Boolean,
        nowMs: Long
    ): PhotonPolicy {
        if (nowMs - lastObserveAtMs !in 0L..MAX_OBSERVE_GAP_MS) {
            cleanGlassWindows = 0
        }
        lastObserveAtMs = nowMs

        val sender = outbound.recent
        val senderFps = sender?.fps.valid()
        val decoderFps = receiver?.fps.valid()
        val presentedFps = receiver?.presentedFps.valid()
        // A measured zero is no media supply, not an unknown counter. Dropping
        // it would compare a quiet stream against the requested FPS ceiling
        // and manufacture a display stall from an empty presentation window.
        val expectedGlassFps =
            listOfNotNull(
                targetFps.toDouble().takeIf { it > 0.0 },
                senderFps,
                decoderFps
            )
                .minOrNull()
        val glassRatio =
            if (
                expectedGlassFps != null &&
                expectedGlassFps > 0.0 &&
                presentedFps != null
            ) {
                (presentedFps / expectedGlassFps)
                    .coerceIn(0.0, 1.25)
            } else {
                null
            }

        val queueMs = sender?.sendQueueMs.valid()
        val encodeMs = sender?.processingMs.valid()
        val decodeMs = receiver?.processingMs.valid()
        val playoutMs = receiver?.playoutDelayMs.valid()
        val pipelineDebtMs =
            listOfNotNull(
                encodeMs,
                queueMs,
                decodeMs,
                playoutMs
            )
                .takeIf { it.isNotEmpty() }
                ?.sum()

        val photonFresh =
            receiver?.photonSampleAgeMs
                ?.let { it in 0..MAX_PHOTON_SAMPLE_AGE_MS } == true
        val inputUpper =
            receiver?.inputToGlassUpperBoundMs
                ?.takeIf { photonFresh }
        val commandAck =
            receiver?.commandAckMs
                ?.takeIf { photonFresh }
        val postAckPresent =
            receiver?.postAckPresentMs
                ?.takeIf { photonFresh }

        val presentationFresh =
            receiver?.presentationSampleAgeMs
                ?.let { it in 0..MAX_GLASS_SAMPLE_AGE_MS } == true
        val actualNewGlassWindow =
            presentationFresh &&
                receiver?.presentationSampleFresh != false &&
                presentedFps != null

        val packetLoss =
            outbound.packetLossRatio.valid()
        val hardPressure =
            queueMs?.let { it >= PRESSURE_QUEUE_MS } == true ||
                playoutMs?.let { it >= PRESSURE_PLAYOUT_MS } == true ||
                receiver?.presentationAgeMs
                    ?.let { it >= PRESSURE_PRESENTATION_AGE_MS } == true ||
                glassRatio?.let { it < PRESSURE_GLASS_RATIO } == true ||
                postAckPresent
                    ?.let { it >= PRESSURE_POST_ACK_PRESENT_MS } == true

        val watchPressure =
            hardPressure ||
                queueMs?.let { it >= WATCH_QUEUE_MS } == true ||
                playoutMs?.let { it >= WATCH_PLAYOUT_MS } == true ||
                receiver?.presentationAgeMs
                    ?.let { it >= WATCH_PRESENTATION_AGE_MS } == true ||
                glassRatio?.let { it < WATCH_GLASS_RATIO } == true ||
                postAckPresent
                    ?.let { it >= WATCH_POST_ACK_PRESENT_MS } == true ||
                packetLoss?.let { it >= WATCH_PACKET_LOSS } == true

        /*
         * Missing sender fractionLost must not freeze the high-FPS ladder on
         * WebRTC/OEMs which omit remote-inbound-rtp. Infer a *limited* clean
         * signal only from an entirely delivered, genuinely new EGL window,
         * zero decoder drops/freezes, known low RTT and steady source supply.
         * Invalid or explicitly high loss never invokes the missing-stat path.
         */
        val lossCleanWithoutCounter =
            outbound.packetLossRatio == null &&
                outbound.roundTripTimeMs?.let {
                    it in 0..MAX_MISSING_LOSS_RTT_MS
                } == true &&
                receiver?.let { measured ->
                    measured.presentationSampleFresh &&
                        measured.dropped == 0 &&
                        measured.freezes == 0 &&
                        measured.maxRenderGapMs?.let {
                            it in 0..MAX_MISSING_LOSS_GLASS_GAP_MS
                        } == true &&
                        senderFps?.let { supplied ->
                            supplied >= MIN_MISSING_LOSS_SUPPLY_FPS &&
                                measured.fps >= minOf(
                                    supplied,
                                    targetFps.toDouble()
                                ) * MIN_MISSING_LOSS_DELIVERY_RATIO
                        } == true
                } == true
        val packetDeliveryClean =
            packetLoss?.let { it < CLEAN_PACKET_LOSS }
                ?: lossCleanWithoutCounter

        val completeCleanEvidence =
            sender != null &&
                sender.intervalMs in 500..6000 &&
                sender.frames >= MIN_MEDIA_FRAMES &&
                receiver != null &&
                receiver.intervalMs in 500..6000 &&
                receiver.frames >= MIN_MEDIA_FRAMES &&
                presentationFresh &&
                presentedFps != null &&
                glassRatio?.let { it >= CLEAN_GLASS_RATIO } == true &&
                queueMs?.let { it <= CLEAN_QUEUE_MS } == true &&
                playoutMs?.let { it <= CLEAN_PLAYOUT_MS } == true &&
                packetDeliveryClean &&
                receiver.presentationAgeMs
                    ?.let { it <= CLEAN_PRESENTATION_AGE_MS } != false &&
                postAckPresent
                    ?.let { it <= CLEAN_POST_ACK_PRESENT_MS } != false

        when {
            hardPressure -> cleanGlassWindows = 0
            actualNewGlassWindow && completeCleanEvidence ->
                cleanGlassWindows =
                    (cleanGlassWindows + 1)
                        .coerceAtMost(MAX_CLEAN_WINDOWS)
            actualNewGlassWindow -> cleanGlassWindows = 0
            // A held sample bridges independently-phased clocks. Do not count
            // it twice, but do not erase valid clean evidence either.
            !presentationFresh -> cleanGlassWindows = 0
        }

        val state =
            when {
                hardPressure -> PhotonFreshnessState.PRESSURE
                watchPressure -> PhotonFreshnessState.WATCH
                completeCleanEvidence -> PhotonFreshnessState.CLEAN
                else -> PhotonFreshnessState.UNKNOWN
            }
        val allowCadencePromotion =
            state == PhotonFreshnessState.CLEAN &&
                cleanGlassWindows >= CLEAN_WINDOWS_FOR_CADENCE
        val allowResolutionRecovery =
            state == PhotonFreshnessState.CLEAN &&
                cleanGlassWindows >= CLEAN_WINDOWS_FOR_DETAIL &&
                !interactionActive

        return PhotonPolicy(
            state = state,
            allowCadencePromotion = allowCadencePromotion,
            allowResolutionRecovery = allowResolutionRecovery,
            glassDeliveryRatio = glassRatio,
            pipelineDebtMs = pipelineDebtMs,
            inputToGlassUpperBoundMs = inputUpper,
            commandAckMs = commandAck,
            postAckPresentMs = postAckPresent,
            cleanGlassWindows = cleanGlassWindows
        ).also { lastPolicy = it }
    }

    fun current(): PhotonPolicy = lastPolicy

    fun reset() {
        cleanGlassWindows = 0
        lastObserveAtMs = Long.MIN_VALUE / 2
        lastPolicy =
            lastPolicy.copy(
                state = PhotonFreshnessState.UNKNOWN,
                allowCadencePromotion = false,
                allowResolutionRecovery = false,
                cleanGlassWindows = 0
            )
    }

    private fun Double?.valid(): Double? =
        this?.takeIf { it.isFinite() && it >= 0.0 }

    private companion object {
        const val MAX_OBSERVE_GAP_MS = 6_000L
        const val MAX_GLASS_SAMPLE_AGE_MS = 1_000
        const val MAX_PHOTON_SAMPLE_AGE_MS = 3_000
        const val MIN_MEDIA_FRAMES = 5
        const val MAX_CLEAN_WINDOWS = 8

        const val CLEAN_WINDOWS_FOR_CADENCE = 2
        const val CLEAN_WINDOWS_FOR_DETAIL = 4

        const val CLEAN_GLASS_RATIO = 0.92
        const val WATCH_GLASS_RATIO = 0.86
        const val PRESSURE_GLASS_RATIO = 0.70

        const val CLEAN_QUEUE_MS = 25.0
        const val WATCH_QUEUE_MS = 50.0
        const val PRESSURE_QUEUE_MS = 120.0

        const val CLEAN_PLAYOUT_MS = 55.0
        const val WATCH_PLAYOUT_MS = 90.0
        const val PRESSURE_PLAYOUT_MS = 160.0

        const val CLEAN_PACKET_LOSS = 0.025
        const val MAX_MISSING_LOSS_RTT_MS = 300
        const val MAX_MISSING_LOSS_GLASS_GAP_MS = 70
        const val MIN_MISSING_LOSS_SUPPLY_FPS = 20.0
        const val MIN_MISSING_LOSS_DELIVERY_RATIO = 0.92
        const val WATCH_PACKET_LOSS = 0.04

        const val CLEAN_PRESENTATION_AGE_MS = 250
        const val WATCH_PRESENTATION_AGE_MS = 500
        const val PRESSURE_PRESENTATION_AGE_MS = 1_200

        const val CLEAN_POST_ACK_PRESENT_MS = 70
        const val WATCH_POST_ACK_PRESENT_MS = 100
        const val PRESSURE_POST_ACK_PRESENT_MS = 180
    }
}
