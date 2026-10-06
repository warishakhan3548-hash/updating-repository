package com.aaris.remoteassist.webrtc

/**
 * Bounds capture cost while libwebrtc remains the owner of bitrate, pacing and
 * congestion control. Freshness wins over nominal FPS: a sustainable cadence
 * is better remote-control UX than a queued/stuttering 60 fps stream.
 */
class VideoCadenceGovernor(
    private val maxFps: Int,
    initialCap: Int = maxFps
) {
    @Volatile
    var cap = initialCap.coerceIn(1, maxFps)
        private set

    private var pressure = 0
    private var healthy = 0
    private var interactiveHeadroom = 0
    private var changedAt = Long.MIN_VALUE / 2
    private var lastOverloadAtMs = Long.MIN_VALUE / 2
    private val highCadenceProbe = HighCadenceProbe()
    val probingHighCadence: Boolean get() = highCadenceProbe.probing

    /**
     * A downshift may survive a long, completely still screen: neither
     * recovery counter can accumulate encoded frames while nothing changes.
     *
     * Probe just ONE rung (never above 30 fps), and only on a genuine new
     * motion transition following recently measured idle and a quiet path.
     * The normal health governor still immediately backs off if motion
     * exposes real encoder/transport pressure.
     */
    fun tryProbeAfterQuiet(
        outbound: VideoHealthSnapshot?,
        producerFps: Double?,
        telemetryAtMs: Long,
        nowMs: Long
    ): Boolean {
        val ceiling = minOf(maxFps, MOTION_RECOVERY_FPS_CEILING)
        if (cap >= ceiling || nowMs < 0L) return false
        if (nowMs - changedAt < QUIET_PROBE_COOLDOWN_MS ||
            nowMs - lastOverloadAtMs < QUIET_PROBE_COOLDOWN_MS) return false
        if (nowMs - telemetryAtMs !in 0L..MAX_IDLE_TELEMETRY_AGE_MS) return false
        if (producerFps == null || !producerFps.isFinite() ||
            producerFps < 0.0 || producerFps >= QUIET_PRODUCER_FPS) return false

        val snapshot = outbound ?: return false
        val window = snapshot.recent ?: return false
        if (window.intervalMs !in 500..6000 ||
            window.frames > MAX_QUIET_ENCODED_FRAMES) return false
        if (snapshot.qualityLimitationReason != null &&
            !snapshot.qualityLimitationReason.equals("none", ignoreCase = true)) return false
        if (snapshot.roundTripTimeMs?.let { it in 0..HEALTHY_RTT_MS } != true) return false
        if ((snapshot.packetLossRatio ?: 0.0) >= HEALTHY_PACKET_LOSS_RATIO) return false
        if (window.sendQueueMs?.let { !it.isFinite() || it < 0.0 ||
            it >= HEALTHY_QUEUE_MS } == true) return false
        if (window.processingMs?.let { !it.isFinite() || it < 0.0 ||
            it >= 1000.0 / ceiling } == true) return false

        val next = ASCENDING_CAPS.firstOrNull { it > cap && it <= ceiling }
            ?: return false
        cap = next
        changedAt = nowMs
        pressure = 0
        healthy = 0
        return true
    }

    /**
     * A real remote-control gesture is authoritative evidence that temporal
     * freshness matters now. If a previous congestion episode left the
     * governor parked at 15/20 fps, immediately restore one bounded interactive
     * floor rather than waiting 8-12 seconds for passive recovery telemetry.
     *
     * This is only a source ceiling. libwebrtc still owns pacing, congestion
     * control and frame dropping, and the normal pressure path can step back
     * down if the fresh probe is not sustainable.
     */
    fun ensureInteractionFloor(
        minimumFps: Int,
        nowMs: Long
    ): Boolean {
        // A finger-down event cannot invalidate measured overload. Otherwise
        // each new gesture reopens the very queue the pressure path just drained.
        if (nowMs - lastOverloadAtMs < QUIET_PROBE_COOLDOWN_MS) return false
        val target = minOf(
            maxFps,
            ASCENDING_CAPS.firstOrNull { it >= minimumFps } ?: minimumFps
        ).coerceAtLeast(1)
        if (cap >= target) return false

        cap = target
        changedAt = nowMs
        pressure = 0
        healthy = 0
        interactiveHeadroom = 0
        return true
    }

    /**
     * Once 24 fps is stable, probe 30 fps quickly when the measured path has
     * real headroom. This avoids the old failure mode where a clean hardware
     * H.264 path stayed self-capped at 15 fps even while MediaProjection was
     * producing 40-50 fresh frames/sec and the sender queue was near zero.
     *
     * Require consecutive healthy windows and a short cooldown after any
     * cadence change. A failed probe naturally falls back through observe().
     */
    fun tryProbeDuringInteraction(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        producerFps: Double?,
        interactionActive: Boolean,
        nowMs: Long
    ): Boolean {
        if (!interactionActive || nowMs - lastOverloadAtMs < INTERACTION_PROBE_COOLDOWN_MS) {
            interactiveHeadroom = 0
            return false
        }

        val ceiling = minOf(maxFps, INTERACTION_PROBE_FPS)
        if (cap >= ceiling) {
            interactiveHeadroom = 0
            return false
        }

        val sender = outbound.recent
        val producerHealthy =
            producerFps != null &&
                producerFps.isFinite() &&
                producerFps >= INTERACTION_PROBE_MIN_PRODUCER_FPS
        val frameBudgetMs = 1000.0 / INTERACTION_PROBE_FPS
        val senderHealthy =
            sender != null &&
                sender.intervalMs in 500..6000 &&
                sender.frames >= MIN_INTERACTION_PROBE_FRAMES &&
                sender.processingMs?.let {
                    it.isFinite() && it >= 0.0 &&
                        it <= frameBudgetMs * INTERACTION_PROBE_CODEC_BUDGET_RATIO
                } == true &&
                sender.sendQueueMs?.let {
                    it.isFinite() && it >= 0.0 &&
                        it <= INTERACTION_PROBE_MAX_QUEUE_MS
                } == true

        val qualityHealthy =
            outbound.qualityLimitationReason == null ||
                outbound.qualityLimitationReason.equals("none", ignoreCase = true)
        val networkHealthy =
            (outbound.roundTripTimeMs?.let { it in 0..INTERACTION_PROBE_MAX_RTT_MS } == true) &&
                (outbound.packetLossRatio ?: 0.0) < INTERACTION_PROBE_MAX_LOSS

        val receiverHealthy =
            receiver?.let { window ->
                window.intervalMs in 500..6000 &&
                    window.frames >= MIN_INTERACTION_PROBE_RECEIVER_FRAMES &&
                    window.processingMs?.let {
                        it.isFinite() && it >= 0.0 &&
                            it <= frameBudgetMs * INTERACTION_PROBE_CODEC_BUDGET_RATIO
                    } != false &&
                    (window.dropped ?: 0) == 0 &&
                    (window.freezes ?: 0) == 0 &&
                    window.presentationAgeMs?.let {
                        it <= INTERACTION_PROBE_MAX_PRESENTATION_AGE_MS
                    } != false
            } ?: true

        val sampleHealthy =
            producerHealthy && senderHealthy && qualityHealthy &&
                networkHealthy && receiverHealthy
        interactiveHeadroom =
            if (sampleHealthy) {
                (interactiveHeadroom + 1).coerceAtMost(INTERACTION_PROBE_SAMPLES)
            } else {
                0
            }

        if (
            interactiveHeadroom < INTERACTION_PROBE_SAMPLES ||
            nowMs - changedAt < INTERACTION_PROBE_COOLDOWN_MS
        ) {
            return false
        }

        cap = ceiling
        changedAt = nowMs
        pressure = 0
        healthy = 0
        interactiveHeadroom = 0
        return true
    }

    fun observe(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        requestedFps: Int,
        nowMs: Long,
        minimumFps: Int = 1,
        producerFps: Double? = null,
        maximumFps: Int = maxFps,
        allowHighCadenceProbe: Boolean = true
    ): Boolean {
        val sender = outbound.recent ?: return false

        // A still producer emits very few fresh frames. Old jitter, loss, or
        // RTT must not ratchet the FPS ceiling downward during silence.
        // Missing producer telemetry preserves the legacy safety logic.
        if (producerFps != null && producerFps.isFinite() &&
            producerFps >= 0.0 && producerFps < QUIET_PRODUCER_FPS &&
            sender.frames <= MAX_QUIET_ENCODED_FRAMES) {
            pressure = 0
            healthy = 0
            interactiveHeadroom = 0
            return false
        }

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
        val receiverMeasured = receiver != null && receiver.frames >= MIN_MEASURED_FRAMES
        val queuePressureThresholdMs = maxOf(MIN_QUEUE_PRESSURE_MS, budgetMs * QUEUE_BUDGET_MULTIPLIER)
        val jitterPressureThresholdMs = maxOf(MIN_JITTER_PRESSURE_MS, budgetMs * JITTER_BUDGET_MULTIPLIER)
        val queuePressure = sendQueueMs != null && sendQueueMs > queuePressureThresholdMs
        val receiverDelay =
            receiverMeasured &&
                receiverJitterMs != null && receiverJitterMs > jitterPressureThresholdMs

        /*
         * A remoting stream can feel late even when no single queue crosses its
         * individual alarm threshold. Sender pacer residence and receiver jitter
         * residence are serial waiting rooms in the same motion-to-photon path,
         * so budget them together as well.
         *
         * The combined budget is deliberately frame-relative. At 60 fps we do
         * not allow roughly four to five old frames to accumulate before reacting:
         * residence above about three frame periods qualifies for the soft
         * 60 -> 45 relief step. At lower cadence the absolute budget expands,
         * avoiding needless quality loss on constrained devices. Full 60 fps may
         * take one early soft relief step; lower cadence retains the established
         * multi-window hysteresis unless pressure is already urgent or severe.
         *
         * Require both measurements for this cross-layer signal. If either
         * endpoint omits its stat, the established per-layer thresholds keep
         * their exact behavior instead of being silently tightened.
         *
         * Libwebrtc still owns bandwidth estimation and packet pacing. This
         * governor only lowers capture cadence when the measured pipeline is
         * accumulating stale frames, which gives GCC room to drain its queues.
         */
        val pipelineResidenceMs =
            if (sendQueueMs != null && receiverMeasured && receiverJitterMs != null) {
                sendQueueMs + receiverJitterMs
            } else {
                null
            }
        val pipelineResidencePressureThresholdMs =
            maxOf(
                MIN_PIPELINE_RESIDENCE_PRESSURE_MS,
                budgetMs * PIPELINE_RESIDENCE_BUDGET_MULTIPLIER
            )
        val pipelineResidencePressure =
            pipelineResidenceMs != null &&
                pipelineResidenceMs > pipelineResidencePressureThresholdMs

        /*
         * RTP/decode counters can look healthy while the controller GPU is
         * visibly hitching. Compare actual EGL swaps against the cadence that
         * made it through sender + decoder, and use long swap gaps as direct
         * motion-to-photon pressure.
         */
        val presentedFrames = receiver?.presentedFrames ?: 0
        val presentedFps = receiver?.presentedFps
        val measuredReceiverFps = receiver?.takeIf { it.frames >= MIN_MEASURED_FRAMES }?.fps
        val expectedPresentationFps = if (presentedFps != null) {
            minOf(requestedFps.toDouble(), sender.fps, measuredReceiverFps ?: Double.POSITIVE_INFINITY)
        } else 0.0
        val presentationRatio =
            if (presentedFps != null && expectedPresentationFps >= MIN_PRESENTATION_EXPECTED_FPS) {
                presentedFps / expectedPresentationFps
            } else 1.0
        val renderGapMs = receiver?.maxRenderGapMs?.toDouble() ?: 0.0
        val renderGapPressureMs = maxOf(MIN_RENDER_GAP_PRESSURE_MS, budgetMs * RENDER_GAP_BUDGET_MULTIPLIER)
        val presentationMeasured =
            presentedFrames >= MIN_PRESENTED_FRAMES && expectedPresentationFps >= MIN_PRESENTATION_EXPECTED_FPS
        val presentationAgeMs = receiver?.presentationAgeMs
        val presentationHeartbeatStalled =
            receiverMeasured &&
                presentationAgeMs != null &&
                presentationAgeMs >= PRESENTATION_HEARTBEAT_STALL_MS
        val presentationPressure =
            (
                presentationMeasured &&
                    (presentationRatio < PRESENTATION_DELIVERY_RATIO || renderGapMs > renderGapPressureMs)
                ) || presentationHeartbeatStalled

        val congestion =
            loss >= PACKET_LOSS_PRESSURE_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= RTT_PRESSURE_MS ||
                queuePressure || receiverDelay || pipelineResidencePressure

        val severePresentationPressure =
            (
                presentationMeasured &&
                    (presentationRatio < SEVERE_PRESENTATION_DELIVERY_RATIO || renderGapMs >= SEVERE_RENDER_GAP_MS)
                ) ||
                (
                    receiverMeasured &&
                        presentationAgeMs != null &&
                        presentationAgeMs >= SEVERE_PRESENTATION_HEARTBEAT_STALL_MS
                    )
        /*
         * A software encoder can collapse to only a handful of frames per
         * second without exposing qualityLimitationReason="cpu". Treat 3-6 fps
         * delivery as real freshness pressure only when encode residence or the
         * sender queue also proves the pipeline is overloaded. This avoids
         * mistaking an intentionally quiet/static screen for encoder failure.
         */
        val senderDeliveryCollapse =
            sender.frames >= MIN_COLLAPSE_MEASURED_FRAMES &&
                sender.fps <= COLLAPSE_FPS &&
                (
                    (sender.processingMs ?: 0.0) >=
                        budgetMs * COLLAPSE_ENCODE_BUDGET_RATIO ||
                        (sendQueueMs ?: 0.0) >=
                            maxOf(
                                COLLAPSE_MIN_QUEUE_MS,
                                budgetMs * COLLAPSE_QUEUE_BUDGET_MULTIPLIER
                            )
                    )

        val severePressure =
            loss >= SEVERE_PACKET_LOSS_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= SEVERE_RTT_MS ||
                (sendQueueMs ?: 0.0) >= SEVERE_QUEUE_MS ||
                (receiverJitterMs ?: 0.0) >= SEVERE_JITTER_MS ||
                (pipelineResidenceMs ?: 0.0) >= SEVERE_PIPELINE_RESIDENCE_MS ||
                receiverDropRatio >= SEVERE_RECEIVER_DROP_RATIO ||
                severePresentationPressure ||
                senderDeliveryCollapse

        /*
         * Remote control is more sensitive to stale frames than a passive call.
         * A queue that is clearly beyond the normal alarm budget should not need
         * a second full stats window before receiving the gentle 60 -> 45 relief.
         * This is intentionally NOT classified as severe: it earns one fast soft
         * cadence step, while 30 fps-or-lower jumps remain reserved for genuinely
         * severe loss/queue/decode/GPU pressure.
         *
         * Requiring 2x the ordinary budget makes this a high-confidence signal.
         * The shorter change interval is bounded to prevent repeated downshifts
         * while GCC is draining the previous queue. Ordinary full-cadence relief
         * is handled separately below and cannot cascade below the 60 -> 45 step.
         */
        val urgentFreshnessPressure =
            !severePressure &&
                (
                    (sendQueueMs ?: 0.0) >= queuePressureThresholdMs * URGENT_FRESHNESS_MULTIPLIER ||
                        (receiverJitterMs ?: 0.0) >= jitterPressureThresholdMs * URGENT_FRESHNESS_MULTIPLIER ||
                        (pipelineResidenceMs ?: 0.0) >=
                            pipelineResidencePressureThresholdMs * URGENT_FRESHNESS_MULTIPLIER ||
                        (presentationMeasured &&
                            renderGapMs >= renderGapPressureMs * URGENT_FRESHNESS_MULTIPLIER)
                    )

        /*
         * Full-cadence remoting has the smallest frame budget. At 60 fps an
         * ordinary, measured queue/jitter/render-pressure crossing already means
         * multiple old frames can sit between the user's finger and the pixels
         * they see. Waiting for a second one-second stats window makes a fast
         * swipe feel sticky even when the control command was applied promptly.
         *
         * Allow exactly one early soft 60 -> 45 relief step. Requiring both the
         * current cap and requested cadence to remain at 60 prevents this signal
         * from cascading below 45; lower rungs retain the established two-window
         * hysteresis unless pressure is urgent or severe.
         */
        val highCadenceFreshnessPressure =
            !severePressure &&
                cap >= HIGH_CADENCE_FAST_RELIEF_FPS &&
                requestedFps >= HIGH_CADENCE_FAST_RELIEF_FPS &&
                (queuePressure || receiverDelay || pipelineResidencePressure || presentationPressure)

        val cpuPressure = outbound.qualityLimitationReason == "cpu"

        val overloaded =
            codecPressure || receiverDrops || congestion || presentationPressure ||
                cpuPressure || senderDeliveryCollapse

        highCadenceProbe.observe(
            outbound, receiver, producerFps, cap, minOf(maxFps, maximumFps),
            allowHighCadenceProbe, overloaded, nowMs
        )?.let { next ->
            cap = next
            changedAt = nowMs
            pressure = 0
            healthy = 0
            interactiveHeadroom = 0
            if (overloaded) lastOverloadAtMs = nowMs
            return true
        }

        if (overloaded) {
            lastOverloadAtMs = nowMs
            healthy = 0
            val pressureWeight =
                if (
                    severePressure ||
                    urgentFreshnessPressure ||
                    highCadenceFreshnessPressure
                ) 2 else 1
            pressure = (pressure + pressureWeight).coerceAtMost(PRESSURE_SAMPLES_TO_REDUCE)
            val changeInterval = when {
                severePressure -> SEVERE_CHANGE_INTERVAL_MS
                urgentFreshnessPressure -> URGENT_FRESHNESS_CHANGE_INTERVAL_MS
                highCadenceFreshnessPressure -> HIGH_CADENCE_FAST_RELIEF_CHANGE_INTERVAL_MS
                else -> MIN_CHANGE_INTERVAL_MS
            }
            if (pressure < PRESSURE_SAMPLES_TO_REDUCE || nowMs - changedAt < changeInterval) return false

            val ceiling = minOf(cap, requestedFps)
            /*
             * 45 fps is an important intermediate rung for ordinary interactive
             * pressure: it avoids the visible 60 -> 30 cliff. Severe queue/jitter/
             * presentation pressure and CPU limitation are different: freshness
             * is already at risk, so they deliberately skip the soft rung and
             * take a stronger <=30 fps relief step.
             */
            val needsStrongRelief = severePressure || cpuPressure
            val ordinaryNext = DESCENDING_CAPS.firstOrNull { candidate ->
                candidate < ceiling &&
                    (!needsStrongRelief || candidate <= STRONG_RELIEF_MAX_STEP_FPS)
            } ?: return false
            val next = if (severePressure) {
                val delivered = buildList {
                    if (sender.frames >= MIN_MEASURED_FRAMES) add(sender.fps)
                    if (receiver != null && receiver.frames >= MIN_MEASURED_FRAMES) add(receiver.fps)
                    if (presentationMeasured && presentedFps != null) add(presentedFps)
                }.minOrNull()
                val guarded = delivered?.times(SEVERE_OBSERVED_HEADROOM)?.toInt()
                if (guarded == null) ordinaryNext
                else DESCENDING_CAPS.firstOrNull {
                    it < ceiling &&
                        it <= guarded &&
                        it <= STRONG_RELIEF_MAX_STEP_FPS
                } ?: ordinaryNext
            } else ordinaryNext

            // Give motion resolution relief time to work before sacrificing
            // cadence. Severe transport failure still has an immediate escape.
            val floor = if (severePressure || cpuPressure) 1
                else minimumFps.coerceIn(1, minOf(cap, requestedFps).coerceAtLeast(1))
            val boundedNext = maxOf(next, floor)
            if (boundedNext >= cap) return false
            cap = boundedNext
            changedAt = nowMs
            pressure = 0
            interactiveHeadroom = 0
            return true
        }

        pressure = 0

        // Above 30 fps only the bounded end-to-end experiment may promote.
        // Decoder-only or absent feedback must not bypass it via legacy recovery.
        if (cap >= 30) return false

        val presentationHealthy =
            !presentationHeartbeatStalled &&
                (
                    !presentationMeasured ||
                        (presentationRatio >= HEALTHY_PRESENTATION_RATIO &&
                            renderGapMs < maxOf(HEALTHY_RENDER_GAP_MS, budgetMs * HEALTHY_RENDER_GAP_BUDGET_MULTIPLIER))
                    )
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

        /*
         * Recovery stays conservative without end-to-end evidence. When the
         * controller proves healthy EGL presentation as well as clean RTP/decode
         * telemetry, five consecutive healthy windows are enough to cautiously
         * probe the next cadence step after five seconds. This prevents a short
         * transient from leaving interaction visibly sluggish for twelve seconds.
         */
        val presentationProvenHealthy = presentationMeasured && presentationHealthy
        val healthySamplesRequired = when {
            receiver == null -> LEGACY_HEALTHY_SAMPLES_TO_RAISE
            presentationProvenHealthy -> PRESENTATION_PROVEN_HEALTHY_SAMPLES_TO_RAISE
            else -> HEALTHY_SAMPLES_TO_RAISE
        }
        val recoveryIntervalMs =
            if (presentationProvenHealthy) PRESENTATION_PROVEN_RECOVERY_INTERVAL_MS
            else MIN_RECOVERY_INTERVAL_MS
        if (healthy < healthySamplesRequired || nowMs - changedAt < recoveryIntervalMs) return false

        val next = ASCENDING_CAPS.firstOrNull { it > cap && it <= minOf(maxFps, maximumFps, 30) } ?: return false
        cap = next
        changedAt = nowMs
        healthy = 0
        return true
    }

    fun mayReduceResolution(nowMs: Long): Boolean =
        cap <= RESOLUTION_REDUCTION_MAX_FPS && nowMs - changedAt >= RESOLUTION_REDUCTION_GRACE_MS

    private companion object {
        val DESCENDING_CAPS = listOf(60, 45, 30, 24, 20, 15)
        val ASCENDING_CAPS = listOf(15, 20, 24, 30, 45, 60)

        const val MOTION_RECOVERY_FPS_CEILING = 30
        const val INTERACTION_PROBE_FPS = 30
        const val INTERACTION_PROBE_MIN_PRODUCER_FPS = 24.0
        const val INTERACTION_PROBE_CODEC_BUDGET_RATIO = 0.80
        const val INTERACTION_PROBE_MAX_QUEUE_MS = 35.0
        const val INTERACTION_PROBE_MAX_RTT_MS = 250
        const val INTERACTION_PROBE_MAX_LOSS = 0.04
        const val INTERACTION_PROBE_MAX_PRESENTATION_AGE_MS = 1_500
        const val MIN_INTERACTION_PROBE_FRAMES = 8
        const val MIN_INTERACTION_PROBE_RECEIVER_FRAMES = 5
        const val INTERACTION_PROBE_SAMPLES = 2
        const val INTERACTION_PROBE_COOLDOWN_MS = 1_500L
        const val QUIET_PRODUCER_FPS = 2.5
        const val MAX_QUIET_ENCODED_FRAMES = 3
        const val QUIET_PROBE_COOLDOWN_MS = 8_000L
        const val MAX_IDLE_TELEMETRY_AGE_MS = 2_500L

        const val MIN_MEASURED_FRAMES = 5
        const val MIN_COLLAPSE_MEASURED_FRAMES = 3
        const val COLLAPSE_FPS = 6.0
        const val COLLAPSE_ENCODE_BUDGET_RATIO = 0.75
        const val COLLAPSE_MIN_QUEUE_MS = 90.0
        const val COLLAPSE_QUEUE_BUDGET_MULTIPLIER = 3.0
        const val MIN_DROPPED_FRAMES_FOR_PRESSURE = 2
        const val MIN_RECEIVER_SAMPLES_FOR_DROP_RATIO = 8
        const val MIN_PRESENTED_FRAMES = 5
        const val MIN_PRESENTATION_EXPECTED_FPS = 10.0
        const val PRESENTATION_HEARTBEAT_STALL_MS = 1_500
        const val SEVERE_PRESENTATION_HEARTBEAT_STALL_MS = 3_000

        const val CODEC_PRESSURE_BUDGET_RATIO = 0.85
        const val CODEC_HEADROOM_BUDGET_RATIO = 0.55
        const val FPS_DELIVERY_RATIO = 0.85

        /*
         * Remote control is freshness-limited, not throughput-limited. At
         * 60 fps, 55-100 ms of residence already represents several obsolete
         * visual states. Keep the alarms frame-relative, but tighten their
         * absolute floor so a fast path sheds work before a visible stale queue
         * forms. Lower cadences still get proportionally larger budgets.
         */
        const val MIN_QUEUE_PRESSURE_MS = 40.0
        const val QUEUE_BUDGET_MULTIPLIER = 1.5
        const val MIN_JITTER_PRESSURE_MS = 70.0
        const val JITTER_BUDGET_MULTIPLIER = 2.0
        const val MIN_PIPELINE_RESIDENCE_PRESSURE_MS = 45.0
        const val PIPELINE_RESIDENCE_BUDGET_MULTIPLIER = 2.25
        const val MIN_RENDER_GAP_PRESSURE_MS = 45.0
        const val RENDER_GAP_BUDGET_MULTIPLIER = 2.25
        const val PRESENTATION_DELIVERY_RATIO = 0.82

        const val PACKET_LOSS_PRESSURE_RATIO = 0.04
        const val RTT_PRESSURE_MS = 650
        const val RECEIVER_DROP_PRESSURE_RATIO = 0.08

        const val SEVERE_PACKET_LOSS_RATIO = 0.12
        const val SEVERE_RTT_MS = 900
        const val SEVERE_QUEUE_MS = 150.0
        const val SEVERE_JITTER_MS = 180.0
        const val SEVERE_PIPELINE_RESIDENCE_MS = 220.0
        const val SEVERE_RECEIVER_DROP_RATIO = 0.25
        const val SEVERE_PRESENTATION_DELIVERY_RATIO = 0.60
        const val SEVERE_RENDER_GAP_MS = 150.0
        const val SEVERE_OBSERVED_HEADROOM = 1.10
        const val STRONG_RELIEF_MAX_STEP_FPS = 30

        const val URGENT_FRESHNESS_MULTIPLIER = 1.75
        const val URGENT_FRESHNESS_CHANGE_INTERVAL_MS = 1_000L
        const val HIGH_CADENCE_FAST_RELIEF_FPS = 60
        const val HIGH_CADENCE_FAST_RELIEF_CHANGE_INTERVAL_MS = 1_000L

        const val HEALTHY_RTT_MS = 300
        const val HEALTHY_JITTER_MS = 45.0
        const val HEALTHY_QUEUE_MS = 20.0
        const val HEALTHY_PACKET_LOSS_RATIO = 0.025
        const val HEALTHY_PRESENTATION_RATIO = 0.90
        const val HEALTHY_RENDER_GAP_MS = 50.0
        const val HEALTHY_RENDER_GAP_BUDGET_MULTIPLIER = 3.0

        const val PRESSURE_SAMPLES_TO_REDUCE = 2
        const val HEALTHY_SAMPLES_TO_RAISE = 8
        const val PRESENTATION_PROVEN_HEALTHY_SAMPLES_TO_RAISE = 5
        const val LEGACY_HEALTHY_SAMPLES_TO_RAISE = 16
        const val MIN_CHANGE_INTERVAL_MS = 3_000L
        const val SEVERE_CHANGE_INTERVAL_MS = 1_000L
        const val MIN_RECOVERY_INTERVAL_MS = 12_000L
        const val PRESENTATION_PROVEN_RECOVERY_INTERVAL_MS = 5_000L

        const val RESOLUTION_REDUCTION_MAX_FPS = 24
        const val RESOLUTION_REDUCTION_GRACE_MS = 6_000L
    }
}
