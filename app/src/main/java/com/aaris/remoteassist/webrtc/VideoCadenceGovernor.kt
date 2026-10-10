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
    private var interactiveFloorHeadroom = 0
    private var changedAt = Long.MIN_VALUE / 2
    private var lastOverloadAtMs = Long.MIN_VALUE / 2
    private var lastDecision = "startup"
    private var lastDeadlineSummary = "deadline=unknown"
    // Completed upstream supply, not the requested source ceiling. Scalar
    // evidence only; capture/RTP frames remain owned by the native pipeline.
    private var lastSenderIdentity: Pair<String, String?>? = null
    private var lastSenderFps: Double? = null
    private var lastSenderAtMs = Long.MIN_VALUE / 2
    private var lastDisplayRefreshRateHz: Double? = null
    private var lastSourceRefreshRateHz: Double? = null
    private val highCadenceProbe = HighCadenceProbe()
    private val highCadencePressureGate = HighCadencePressureGate()
    val probingHighCadence: Boolean get() = highCadenceProbe.probing

    /**
     * Source geometry is an expensive encoder operating-point transition.
     *
     * The resize itself already acted on the current pressure sample, so clear
     * temporal votes derived from the old geometry instead of letting the same
     * telemetry window also downshift cadence. The learned FPS cap survives;
     * only stale pre-transition evidence is discarded.
     */
    fun onSpatialBudgetTransition(nowMs: Long) {
        if (nowMs < 0L) return

        pressure = 0
        healthy = 0
        interactiveHeadroom = 0
        interactiveFloorHeadroom = 0
        lastSenderIdentity = null
        lastSenderFps = null
        lastSenderAtMs = Long.MIN_VALUE / 2
        highCadencePressureGate.reset()
        highCadenceProbe.onSpatialBudgetTransition(
            currentFps = cap,
            nowMs = nowMs
        )
        lastDecision = "spatial-budget-hold@$cap"
    }

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
        nowMs: Long,
        maximumFps: Int = maxFps
    ): Boolean {
        val ceiling =
            minOf(
                maxFps,
                maximumFps.coerceAtLeast(1),
                MOTION_RECOVERY_FPS_CEILING
            )
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

        val next = LOW_ASCENDING_CAPS.firstOrNull { it > cap && it <= ceiling }
            ?: return false
        cap = next
        changedAt = nowMs
        pressure = 0
        healthy = 0
        lastDecision = "quiet-recovery->$next"
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
            LOW_ASCENDING_CAPS.firstOrNull { it >= minimumFps } ?: minimumFps
        ).coerceAtLeast(1)
        if (cap >= target) return false

        cap = target
        changedAt = nowMs
        pressure = 0
        healthy = 0
        interactiveHeadroom = 0
        interactiveFloorHeadroom = 0
        lastDecision = "interaction-floor->$target"
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
        nowMs: Long,
        maximumFps: Int = maxFps
    ): Boolean {
        if (!interactionActive) {
            interactiveHeadroom = 0
            interactiveFloorHeadroom = 0
            return false
        }

        /*
         * The governor instance is session-wide so HIGH devices may eventually
         * reach 60 fps, but the active CaptureProfile is a stricter per-device
         * contract. Never let interaction rescue/probing escape that contract.
         * This is especially important for LOW/BALANCED devices whose safe
         * motion ceilings are intentionally 20/30 fps.
         */
        val boundedMaximumFps =
            maximumFps.coerceIn(1, maxFps)
        val sender = outbound.recent

        /*
         * A recent overload must block blind finger-down promotion, but it must
         * not pin a recovered path at 15/20 fps for the whole cooldown. When
         * active motion itself proves that 24 fps fits the encoder + pacer +
         * network budget for two fresh windows, rescue only to 24. The normal
         * 30/45/60 probes still require their stricter evidence.
         */
        val interactionFloorTarget =
            minOf(boundedMaximumFps, INTERACTION_RESCUE_FLOOR_FPS)
        if (cap < interactionFloorTarget) {
            val floorBudgetMs = 1_000.0 / interactionFloorTarget
            val producerHealthy =
                producerFps != null &&
                    producerFps.isFinite() &&
                    producerFps >= interactionFloorTarget * 0.90
            val senderHealthy =
                sender != null &&
                    sender.intervalMs in 500..6000 &&
                    sender.frames >= MIN_INTERACTION_FLOOR_FRAMES &&
                    sender.processingMs?.let {
                        it.isFinite() && it >= 0.0 &&
                            it <= floorBudgetMs * INTERACTION_FLOOR_CODEC_BUDGET_RATIO
                    } == true &&
                    sender.sendQueueMs?.let {
                        it.isFinite() && it >= 0.0 &&
                            it <= INTERACTION_FLOOR_MAX_QUEUE_MS
                    } == true
            val qualityHealthy =
                outbound.qualityLimitationReason == null ||
                    outbound.qualityLimitationReason.equals("none", ignoreCase = true)
            /*
             * Emergency rescue below 24 fps is intentionally more tolerant
             * than a 24 -> 30 promotion. At 240/360-wide emergency rungs a
             * recovered zero-queue hardware path can still deliver useful
             * fresh motion with moderate residual loss. Requiring <4% loss here
             * made real mobile paths stick at 15 fps long after congestion had
             * cleared. Severe loss still blocks rescue; the 30-fps probe below
             * retains the stricter threshold.
             */
            val floorLossLimit =
                if (cap <= STICKY_LOW_CADENCE_FPS) {
                    INTERACTION_FLOOR_RECOVERY_MAX_LOSS
                } else {
                    INTERACTION_FLOOR_MAX_LOSS
                }
            val floorRttLimit =
                if (cap <= STICKY_LOW_CADENCE_FPS) {
                    INTERACTION_FLOOR_RECOVERY_MAX_RTT_MS
                } else {
                    INTERACTION_FLOOR_MAX_RTT_MS
                }
            val networkHealthy =
                outbound.roundTripTimeMs?.let {
                    it in 0..floorRttLimit
                } == true &&
                    (outbound.packetLossRatio ?: 0.0) <
                        floorLossLimit
            val receiverHealthy =
                receiver?.let { window ->
                    window.processingMs?.let {
                        it.isFinite() && it >= 0.0 &&
                            it <= floorBudgetMs *
                                INTERACTION_FLOOR_CODEC_BUDGET_RATIO
                    } != false &&
                        (window.dropped ?: 0) == 0 &&
                        (window.freezes ?: 0) == 0 &&
                        window.presentationAgeMs?.let {
                            it <= INTERACTION_FLOOR_MAX_PRESENTATION_AGE_MS
                        } != false
                } ?: true

            val floorHealthy =
                producerHealthy && senderHealthy && qualityHealthy &&
                    networkHealthy && receiverHealthy
            interactiveFloorHeadroom =
                if (floorHealthy) {
                    (interactiveFloorHeadroom + 1)
                        .coerceAtMost(INTERACTION_FLOOR_SAMPLES)
                } else {
                    0
                }

            if (
                interactiveFloorHeadroom >= INTERACTION_FLOOR_SAMPLES &&
                nowMs - changedAt >= INTERACTION_FLOOR_MIN_CHANGE_INTERVAL_MS
            ) {
                cap = interactionFloorTarget
                changedAt = nowMs
                pressure = 0
                healthy = 0
                interactiveHeadroom = 0
                interactiveFloorHeadroom = 0
                lastDecision =
                    "interaction-clean-rescue->$interactionFloorTarget"
                return true
            }
            return false
        }

        interactiveFloorHeadroom = 0

        if (nowMs - lastOverloadAtMs < INTERACTION_PROBE_COOLDOWN_MS) {
            interactiveHeadroom = 0
            return false
        }

        val ceiling =
            minOf(boundedMaximumFps, INTERACTION_PROBE_FPS)
        if (cap >= ceiling) {
            interactiveHeadroom = 0
            return false
        }
        val producerHealthy =
            producerFps != null &&
                producerFps.isFinite() &&
                producerFps >= INTERACTION_PROBE_MIN_PRODUCER_FPS
        val frameBudgetMs = 1000.0 / ceiling.coerceAtLeast(1)
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
        interactiveFloorHeadroom = 0
        lastDecision = "interaction-headroom->$ceiling"
        return true
    }

    /**
     * Fast receiver-presentation brake for active remote control.
     *
     * The controller already reports real EGL swaps in bounded ~500 ms windows.
     * Consuming that signal only on the next one-second getStats() callback adds
     * avoidable stale-frame latency. This path is intentionally one-way: it may
     * lower cadence when the glass is visibly hitching, but it can never promote
     * FPS or estimate bandwidth. GCC/TWCC and the full telemetry governor remain
     * authoritative for network adaptation and recovery.
     *
     * A requested 60 fps ceiling does not prove 60 frames were supplied. Compare
     * glass cadence with recent completed sender supply; sparse/unknown/expired
     * supply cannot establish a fast display-overload vote.
     *
     * At high cadence one trustworthy hitch earns one display-paced relief
     * step. This avoids long frame/vsync beat patterns such as 58/60 while a
     * large fall toward 30 still requires severe presentation/pipeline evidence.
     * The bounded cooldown plus one-step rule prevents one scheduler pause from
     * cascading through multiple levels.
     */
    fun observeFastPresentation(
        intervalMs: Int,
        renderedFrames: Int,
        maxGapMs: Int,
        requestedFps: Int,
        interactionActive: Boolean,
        nowMs: Long,
        displayRefreshRateHz: Double? = null
    ): Boolean {
        displayRefreshRateHz
            ?.takeIf {
                it.isFinite() &&
                    it in MIN_DISPLAY_REFRESH_HZ..MAX_DISPLAY_REFRESH_HZ
            }
            ?.let { lastDisplayRefreshRateHz = it }
        if (
            !interactionActive ||
            nowMs < 0L ||
            intervalMs !in FAST_PRESENTATION_MIN_WINDOW_MS..
                FAST_PRESENTATION_MAX_WINDOW_MS ||
            renderedFrames < FAST_PRESENTATION_MIN_FRAMES ||
            maxGapMs !in 0..6_000 ||
            cap < FAST_PRESENTATION_MIN_CADENCE_FPS ||
            requestedFps < FAST_PRESENTATION_MIN_CADENCE_FPS ||
            nowMs - changedAt < FAST_PRESENTATION_CHANGE_INTERVAL_MS
        ) {
            return false
        }

        val effectiveFps =
            minOf(cap, requestedFps, maxFps)
                .coerceAtLeast(1)
        if (effectiveFps < FAST_PRESENTATION_MIN_CADENCE_FPS) {
            return false
        }

        val suppliedFps = lastSenderFps
        if (
            suppliedFps == null ||
            nowMs - lastSenderAtMs !in 0L..FAST_PRESENTATION_MAX_SENDER_AGE_MS
        ) {
            highCadencePressureGate.clearPresentation()
            return false
        }
        val expectedFps = minOf(effectiveFps.toDouble(), suppliedFps)
        if (expectedFps < MIN_PRESENTATION_EXPECTED_FPS) {
            highCadencePressureGate.clearPresentation()
            return false
        }

        val measuredFps =
            renderedFrames * 1_000.0 / intervalMs.toDouble()
        val deliveryRatio =
            measuredFps / expectedFps
        val frameBudgetMs =
            1_000.0 / expectedFps

        val severeGapMs =
            maxOf(
                FAST_PRESENTATION_SEVERE_GAP_MS,
                frameBudgetMs *
                    FAST_PRESENTATION_SEVERE_GAP_MULTIPLIER
            )
        val severe =
            deliveryRatio <
                FAST_PRESENTATION_SEVERE_DELIVERY_RATIO ||
                maxGapMs >= severeGapMs

        val fullCadenceGapMs =
            maxOf(
                FAST_PRESENTATION_FULL_CADENCE_GAP_MS,
                frameBudgetMs *
                    FAST_PRESENTATION_FULL_CADENCE_GAP_MULTIPLIER
            )
        val fullCadencePressure =
            effectiveFps >= HIGH_CADENCE_FAST_RELIEF_FPS &&
                (
                    deliveryRatio <
                        FAST_PRESENTATION_FULL_CADENCE_DELIVERY_RATIO ||
                        maxGapMs >= fullCadenceGapMs
                    )

        /*
         * A single moderate full-cadence hitch is evidence, not yet proof of a
         * sustainable overload. Require a second distinct EGL window before
         * trimming 60 fps. Severe presentation pressure bypasses confirmation,
         * but still receives only the bounded one-rung presentation relief
         * below. The gate keeps this render-clock evidence separate from the
         * getStats lane so the same physical hitch cannot be double-counted.
         */
        if (
            !highCadencePressureGate.observePresentation(
                nowMs = nowMs,
                softPressure = fullCadencePressure,
                severePressure = severe
            )
        ) {
            return false
        }

        /*
         * Presentation-only evidence never skips a rung. That makes this safe
         * when the network is actually healthy and the hitch came from a brief
         * controller-side scheduling/GPU pause. Full getStats telemetry can
         * still take a stronger step for proven CPU/queue/loss pressure.
         */
        val next =
            DisplayCadencePolicy.nextLower(
                currentFps = effectiveFps,
                refreshRateHz = lastDisplayRefreshRateHz,
                floorFps = 1,
                ceilingFps = maxFps,
                sourceRefreshRateHz = lastSourceRefreshRateHz
            )?.takeIf { it < cap } ?: return false

        // Moderate presentation-only relief is deliberately one fine step.
        if (!severe && next < SOFT_PRESENTATION_RELIEF_FPS) {
            return false
        }

        cap = next
        changedAt = nowMs
        lastOverloadAtMs = nowMs
        pressure = 0
        healthy = 0
        interactiveHeadroom = 0
        interactiveFloorHeadroom = 0
        lastDecision = "fast-presentation-relief->$next"
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
        allowHighCadenceProbe: Boolean = true,
        sourceRefreshRateHz: Double? = null
    ): Boolean {
        val senderIdentity = outbound.streamId to outbound.codec
        if (senderIdentity != lastSenderIdentity) {
            lastSenderIdentity = senderIdentity
            lastSenderFps = null
            highCadencePressureGate.clearPresentation()
        }
        receiver?.displayRefreshRateHz
            ?.takeIf {
                it.isFinite() &&
                    it in MIN_DISPLAY_REFRESH_HZ..MAX_DISPLAY_REFRESH_HZ
            }
            ?.let { lastDisplayRefreshRateHz = it }
        sourceRefreshRateHz
            ?.takeIf {
                it.isFinite() &&
                    it in MIN_DISPLAY_REFRESH_HZ..MAX_DISPLAY_REFRESH_HZ
            }
            ?.let { lastSourceRefreshRateHz = it }

        val sender = outbound.recent ?: return false
        lastSenderFps = sender.fps.takeIf {
            nowMs >= 0L &&
                sender.intervalMs in FAST_PRESENTATION_MIN_WINDOW_MS..
                    FAST_PRESENTATION_MAX_WINDOW_MS &&
                sender.frames in 0..2048 &&
                it.isFinite() && it >= 0.0
        }
        lastSenderAtMs = nowMs

        if (
            cap < HIGH_CADENCE_FAST_RELIEF_FPS ||
            requestedFps < HIGH_CADENCE_FAST_RELIEF_FPS
        ) {
            // Soft full-cadence evidence must never survive a downshift and
            // become a stale vote after a later promotion back to 60 fps.
            highCadencePressureGate.reset()
        }

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
         * One deadline controller owns controllable staleness. It intentionally
         * excludes path propagation (RTT/2): cadence cannot make physics faster,
         * but it can stop codec/pacer/playout queues from retaining obsolete
         * screen states. Complete evidence collapses encode + sender-pacer +
         * decode + receiver-playout residence into one frame-relative signal.
         *
         * If an endpoint does not expose residence, the established per-layer
         * alarms remain a conservative fallback rather than inventing latency.
         * Libwebrtc continues to own GCC/TWCC and packet pacing.
         */
        val freshnessDeadline =
            FreshnessDeadlineController.assess(
                targetFps = requestedFps,
                sender = sender,
                receiver = receiver?.takeIf { receiverMeasured }
            )
        lastDeadlineSummary = freshnessDeadline.compact()
        val pipelineResidencePressure = freshnessDeadline.pressure
        val fallbackLayerPressure =
            !freshnessDeadline.complete &&
                (queuePressure || receiverDelay)

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
        /*
         * A retained presentation sample bridges stats/render phase skew, but
         * it is not a second pressure event. Fast presentation handling already
         * reacts immediately when the real packet arrives; the full governor
         * must not cascade another downshift by re-counting the same EGL window.
         */
        val presentationCadenceFresh =
            receiver?.presentationSampleFresh != false
        val presentationMeasured =
            presentationCadenceFresh &&
                presentedFrames >= MIN_PRESENTED_FRAMES &&
                expectedPresentationFps >= MIN_PRESENTATION_EXPECTED_FPS
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
                pipelineResidencePressure || fallbackLayerPressure

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

        val fallbackSevereResidence =
            !freshnessDeadline.complete &&
                (
                    (sendQueueMs ?: 0.0) >= SEVERE_QUEUE_MS ||
                        (receiverJitterMs ?: 0.0) >= SEVERE_JITTER_MS
                    )
        val severePressure =
            loss >= SEVERE_PACKET_LOSS_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= SEVERE_RTT_MS ||
                freshnessDeadline.severe ||
                fallbackSevereResidence ||
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
        val fallbackUrgentResidence =
            !freshnessDeadline.complete &&
                (
                    (sendQueueMs ?: 0.0) >= queuePressureThresholdMs * URGENT_FRESHNESS_MULTIPLIER ||
                        (receiverJitterMs ?: 0.0) >= jitterPressureThresholdMs * URGENT_FRESHNESS_MULTIPLIER
                    )
        val urgentFreshnessPressure =
            !severePressure &&
                (
                    freshnessDeadline.urgent ||
                        fallbackUrgentResidence ||
                        (presentationMeasured &&
                            renderGapMs >= renderGapPressureMs * URGENT_FRESHNESS_MULTIPLIER)
                    )

        /*
         * Full-cadence remoting has the smallest frame budget, but one ordinary
         * mobile-network or scheduler excursion is not enough to prove that 60
         * fps is unsustainable. Keep this signal scoped to full cadence, then
         * let the confidence gate distinguish isolated evidence from sustained
         * pressure. Confirmed soft pressure earns only the next fine rung
         * (normally 60 -> 58); urgent/severe evidence still bypasses the gate.
         */
        val highCadenceResidencePressure =
            pipelineResidencePressure || fallbackLayerPressure
        val highCadenceFreshnessPressure =
            !severePressure &&
                !urgentFreshnessPressure &&
                cap >= HIGH_CADENCE_FAST_RELIEF_FPS &&
                requestedFps >= HIGH_CADENCE_FAST_RELIEF_FPS &&
                (highCadenceResidencePressure || presentationPressure)

        /*
         * One ordinary 60-fps queue/render crossing is allowed to be transient.
         * Two fresh telemetry windows confirm it. If residence and actual glass
         * presentation are both bad inside the same stats snapshot, independent
         * domains corroborate the event and one fine relief step may happen
         * immediately. Urgent/severe pressure never waits on this soft gate.
         */
        val highCadenceFreshnessConfirmed =
            if (severePressure || urgentFreshnessPressure) {
                highCadencePressureGate.reset()
                false
            } else {
                highCadencePressureGate.observeTelemetry(
                    nowMs = nowMs,
                    softPressure = highCadenceFreshnessPressure,
                    corroborated =
                        highCadenceResidencePressure &&
                            presentationPressure
                )
            }

        val cpuPressure = outbound.qualityLimitationReason == "cpu"

        val overloaded =
            codecPressure || receiverDrops || congestion || presentationPressure ||
                cpuPressure || senderDeliveryCollapse

        /*
         * A high-cadence trial must not roll back on one ordinary mobile-network
         * blip. Promotion eligibility already rejects that sample, so the trial
         * simply stops accumulating proof. Roll back immediately only for true
         * emergency/device collapse, corroborated high-cadence staleness, or a
         * second consecutive ordinary overload window.
         */
        val probeOverloadConfirmed =
            severePressure ||
                urgentFreshnessPressure ||
                cpuPressure ||
                senderDeliveryCollapse ||
                highCadenceFreshnessConfirmed ||
                (
                    overloaded &&
                        pressure >= PRESSURE_SAMPLES_TO_REDUCE - 1
                    )

        highCadenceProbe.observe(
            outbound, receiver, producerFps, cap, minOf(maxFps, maximumFps),
            allowHighCadenceProbe, probeOverloadConfirmed, nowMs,
            sourceRefreshRateHz = lastSourceRefreshRateHz
        )?.let { next ->
            val before = cap
            cap = next
            changedAt = nowMs
            pressure = 0
            healthy = 0
            interactiveHeadroom = 0
            interactiveFloorHeadroom = 0
            if (overloaded) lastOverloadAtMs = nowMs
            lastDecision =
                if (next > before) {
                    "high-probe->$next"
                } else {
                    "high-probe-rollback->$next"
                }
            return true
        }

        if (overloaded) {
            lastOverloadAtMs = nowMs
            healthy = 0
            val pressureWeight =
                if (
                    severePressure ||
                    urgentFreshnessPressure ||
                    highCadenceFreshnessConfirmed
                ) 2 else 1
            pressure = (pressure + pressureWeight).coerceAtMost(PRESSURE_SAMPLES_TO_REDUCE)
            val changeInterval = when {
                severePressure -> SEVERE_CHANGE_INTERVAL_MS
                urgentFreshnessPressure -> URGENT_FRESHNESS_CHANGE_INTERVAL_MS
                highCadenceFreshnessConfirmed -> HIGH_CADENCE_FAST_RELIEF_CHANGE_INTERVAL_MS
                else -> MIN_CHANGE_INTERVAL_MS
            }
            if (pressure < PRESSURE_SAMPLES_TO_REDUCE || nowMs - changedAt < changeInterval) return false

            val ceiling = minOf(cap, requestedFps)
            /*
             * Ordinary pressure takes one display-paced rung. Numerically tiny
             * near-refresh trims can create long frame/vsync beat periods and
             * visible micro-stutter even when the pipeline is otherwise healthy.
             * Severe queue/jitter/presentation pressure and CPU limitation may
             * still jump directly to the <=30 fps freshness ladder.
             */
            val needsStrongRelief = severePressure || cpuPressure
            val cadenceSteps =
                DisplayCadencePolicy.descending(
                    refreshRateHz = lastDisplayRefreshRateHz,
                    ceilingFps = maxFps,
                    floorFps = 1,
                    sourceRefreshRateHz = lastSourceRefreshRateHz
                )
            val ordinaryNext = cadenceSteps.firstOrNull { candidate ->
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
                else cadenceSteps.firstOrNull {
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
            interactiveFloorHeadroom = 0
            lastDecision =
                when {
                    cpuPressure -> "cpu-relief->$boundedNext"
                    severePressure -> "severe-relief->$boundedNext"
                    presentationPressure -> "presentation-relief->$boundedNext"
                    pipelineResidencePressure || fallbackLayerPressure ->
                        "deadline-relief->$boundedNext"
                    receiverDelay -> "jitter-relief->$boundedNext"
                    codecPressure -> "codec-relief->$boundedNext"
                    loss >= PACKET_LOSS_PRESSURE_RATIO ->
                        "loss-relief->$boundedNext"
                    else -> "pressure-relief->$boundedNext"
                }
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

        val next = LOW_ASCENDING_CAPS.firstOrNull { it > cap && it <= minOf(maxFps, maximumFps, 30) } ?: return false
        cap = next
        changedAt = nowMs
        healthy = 0
        lastDecision = "healthy-recovery->$next"
        return true
    }

    /**
     * Reuses governor state already maintained for adaptation. This is sampled
     * by the existing 3-second on-screen QD path and performs no media work.
     */
    fun debugSummary(nowMs: Long): String {
        fun ageMs(timestampMs: Long): String {
            if (timestampMs <= Long.MIN_VALUE / 4) return "none"
            return (nowMs - timestampMs)
                .coerceAtLeast(0L)
                .let { "${it}ms" }
        }

        return "cap=${cap}fps decision=$lastDecision " +
            "$lastDeadlineSummary " +
            highCadencePressureGate.compact(nowMs) + " " +
            "changeAgo=${ageMs(changedAt)} " +
            "overloadAgo=${ageMs(lastOverloadAtMs)} " +
            "floorProof=$interactiveFloorHeadroom/$INTERACTION_FLOOR_SAMPLES " +
            highCadenceProbe.debugSummary(nowMs)
    }

    fun mayReduceResolution(nowMs: Long): Boolean =
        cap <= RESOLUTION_REDUCTION_MAX_FPS && nowMs - changedAt >= RESOLUTION_REDUCTION_GRACE_MS

    private companion object {
        val LOW_ASCENDING_CAPS =
            listOf(15, 20, 24, 30)

        const val MIN_DISPLAY_REFRESH_HZ = 30.0
        const val MAX_DISPLAY_REFRESH_HZ = 240.0
        const val MOTION_RECOVERY_FPS_CEILING = 30
        const val INTERACTION_RESCUE_FLOOR_FPS = 24
        const val INTERACTION_FLOOR_CODEC_BUDGET_RATIO = 0.85
        const val INTERACTION_FLOOR_MAX_QUEUE_MS = 25.0
        const val INTERACTION_FLOOR_MAX_RTT_MS = 300
        const val INTERACTION_FLOOR_MAX_LOSS = 0.04
        const val STICKY_LOW_CADENCE_FPS = 15
        const val INTERACTION_FLOOR_RECOVERY_MAX_RTT_MS = 350
        const val INTERACTION_FLOOR_RECOVERY_MAX_LOSS = 0.08
        const val INTERACTION_FLOOR_MAX_PRESENTATION_AGE_MS = 1_500
        const val MIN_INTERACTION_FLOOR_FRAMES = 5
        const val INTERACTION_FLOOR_SAMPLES = 2
        const val INTERACTION_FLOOR_MIN_CHANGE_INTERVAL_MS = 500L

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
        const val MIN_JITTER_PRESSURE_MS = 85.0
        const val JITTER_BUDGET_MULTIPLIER = 2.0
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
        const val SEVERE_RECEIVER_DROP_RATIO = 0.25
        const val SEVERE_PRESENTATION_DELIVERY_RATIO = 0.60
        const val SEVERE_RENDER_GAP_MS = 150.0
        const val SEVERE_OBSERVED_HEADROOM = 1.10
        const val STRONG_RELIEF_MAX_STEP_FPS = 30

        const val URGENT_FRESHNESS_MULTIPLIER = 1.75
        const val URGENT_FRESHNESS_CHANGE_INTERVAL_MS = 1_500L
        const val HIGH_CADENCE_FAST_RELIEF_FPS = 60
        const val HIGH_CADENCE_FAST_RELIEF_CHANGE_INTERVAL_MS = 1_000L

        /*
         * Controller EGL feedback arrives independently of getStats(). Keep the
         * fast path bounded to recent half-second-ish windows and high cadence.
         */
        const val FAST_PRESENTATION_MIN_WINDOW_MS = 500
        const val FAST_PRESENTATION_MAX_WINDOW_MS = 2_000
        const val FAST_PRESENTATION_MAX_SENDER_AGE_MS = 1_500L
        const val FAST_PRESENTATION_MIN_FRAMES = 5
        const val FAST_PRESENTATION_MIN_CADENCE_FPS = 45
        const val FAST_PRESENTATION_CHANGE_INTERVAL_MS = 450L
        const val FAST_PRESENTATION_FULL_CADENCE_DELIVERY_RATIO = 0.75
        const val FAST_PRESENTATION_FULL_CADENCE_GAP_MS = 70.0
        const val FAST_PRESENTATION_FULL_CADENCE_GAP_MULTIPLIER = 3.0
        const val FAST_PRESENTATION_SEVERE_DELIVERY_RATIO = 0.55
        const val FAST_PRESENTATION_SEVERE_GAP_MS = 140.0
        const val FAST_PRESENTATION_SEVERE_GAP_MULTIPLIER = 5.0
        const val SOFT_PRESENTATION_RELIEF_FPS = 45

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
