package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import kotlin.math.roundToInt

/**
 * Motion trades pixels before cadence. One-second interval telemetry drives a
 * 720 -> 540 -> 360 -> 240 ladder, with a final 180 short-edge freshness rung
 * only when moving-source evidence proves a bandwidth-limited stale queue.
 * The MediaProjection surface never changes.
 *
 * The key invariant is "new pixels beat old pixels": under congestion we spend
 * resolution before cadence so WebRTC's MAINTAIN_FRAMERATE policy is not
 * accidentally defeated by our own source cap. The cadence governor remains
 * the final escape hatch when even the smallest frame cannot be delivered
 * promptly.
 */
internal class MotionVideoBudget {
    var shortEdge = 720
        private set
    private var holdingResolution = false
    private var lastMotionAtMs = Long.MIN_VALUE / 2
    private var changedAtMs = Long.MIN_VALUE / 2
    private var lastMeasuredSenderAtMs = Long.MIN_VALUE / 2
    private var lastMeasuredSenderStreamId: String? = null
    private var lastMeasuredSenderCodec: String? = null
    private var pressureSamples = 0
    private var healthySamples = 0
    private var lastImplementation: String? = null
    private var lastBandwidthPressureAtMs = Long.MIN_VALUE / 2

    /*
     * Entering motion may choose a conservative bitrate/pixel budget before a
     * complete moving-window sample exists. Do not immediately turn that
     * prediction into a VideoSource dimension change: vendor MediaCodec
     * implementations may reconfigure at exactly the first touch/scroll frame.
     *
     * The speculative rung may cap bitrate immediately, but source geometry is
     * held at the pre-motion rung until one complete motion sample either
     * confirms pressure or proves the path healthy. Measured pressure still
     * receives immediate app-level pixel relief after that first window.
     */
    private var warmStartResizePending = false
    private var preMotionShortEdge = 720

    /*
     * Predict freshness debt before it becomes an absolute queue alarm.
     * These are control-plane scalars only: no frame, texture or packet is
     * retained. The composition flag prevents a newly available receiver
     * jitter sample from looking like artificial queue growth.
     */
    private var previousResidenceMs: Double? = null
    private var previousResidenceAtMs = Long.MIN_VALUE / 2
    private var previousResidenceUsesReceiver = false
    private var residenceGrowthSamples = 0

    /**
     * New motion must not blindly pay a MediaCodec resolution restart.
     *
     * Unknown / software / pressured paths may select a conservative
     * 360-short-edge control budget. When the immediately preceding quiet
     * WebRTC sample proves a fast hardware encoder plus real bandwidth
     * headroom, the control budget may preserve 540 or 720 instead.
     *
     * Crucially, a predicted lower rung is not applied to VideoSource geometry
     * on touch-down. It may cap bitrate immediately, but a real moving-window
     * pressure sample must confirm the source resize first.
     *
     * Repeated motion pulses only refresh the hold; they never knock a
     * continuously healthy stream back down after the first decision.
     */
    fun primeForMotion(
        profile: CaptureProfile,
        nowMs: Long,
        warmStartEvidence: VideoHealthSnapshot? = null,
        targetFps: Int = BASELINE_MOTION_FPS
    ): Boolean {
        if (nowMs < 0L) return false

        val before = Triple(
            shortEdge,
            holdingResolution,
            warmStartResizePending
        )
        val enteringMotion = !holdingResolution
        holdingResolution = true
        lastMotionAtMs = nowMs

        if (enteringMotion) {
            pressureSamples = 0
            healthySamples = 0
            resetResidenceGrowth()
            preMotionShortEdge = shortEdge
            warmStartResizePending = false

            val profileShortEdge =
                minOf(profile.captureWidthPx, profile.captureHeightPx)
            val warmStartShortEdge =
                motionWarmStartShortEdge(
                    profile = profile,
                    evidence = warmStartEvidence,
                    targetFps = targetFps
                )
            if (
                profileShortEdge > warmStartShortEdge &&
                shortEdge > warmStartShortEdge
            ) {
                shortEdge = warmStartShortEdge
                warmStartResizePending = true
                changedAtMs = nowMs
            }
        }

        return before != Triple(
            shortEdge,
            holdingResolution,
            warmStartResizePending
        )
    }

    fun observe(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        sourceFps: Double?,
        motionActive: Boolean,
        targetFps: Int,
        nowMs: Long,
        interactionActive: Boolean = false,
        allowResolutionRecovery: Boolean = true
    ): Boolean {
        val before = Triple(
            shortEdge,
            holdingResolution,
            warmStartResizePending
        )
        val enteringMotion = !holdingResolution
        if (!motionActive) {
            /*
             * If motion ended before a complete moving-window sample validated
             * the speculative warm-start rung, discard that prediction. This
             * prevents a delayed idle callback from applying a touch-down
             * resolution change after the gesture has already finished.
             */
            if (warmStartResizePending) {
                shortEdge = preMotionShortEdge
                warmStartResizePending = false
            }
            pressureSamples = 0
            healthySamples = 0
            resetResidenceGrowth()
            if (nowMs - lastMotionAtMs >= IDLE_RESTORE_MS) {
                lastBandwidthPressureAtMs = Long.MIN_VALUE / 2
                holdingResolution = false
                shortEdge = 720
            }
            return before != Triple(
                shortEdge,
                holdingResolution,
                warmStartResizePending
            )
        }
        holdingResolution = true
        lastMotionAtMs = nowMs
        val sender = outbound.recent?.takeIf { it.intervalMs in 500..6000 && it.frames >= 0 }
        // A track/codec replacement starts a new pressure history even if its
        // first WebRTC stats callbacks have no completed interval yet.
        if (
            lastMeasuredSenderStreamId != null &&
            (outbound.streamId != lastMeasuredSenderStreamId ||
                outbound.codec != lastMeasuredSenderCodec)
        ) {
            pressureSamples = 0
            healthySamples = 0
            resetResidenceGrowth()
            lastMeasuredSenderAtMs = Long.MIN_VALUE / 2
        }
        if (sender == null) {
            // Short getStats probes do not have a complete sender interval.
            // Ignore them instead of erasing validated congestion evidence.
            // Expire that evidence on the next complete sample after a long gap.
            return before != Triple(
                shortEdge,
                holdingResolution,
                warmStartResizePending
            )
        }
        if (nowMs - lastMeasuredSenderAtMs !in 0L..MAX_SENDER_SAMPLE_GAP_MS) {
            pressureSamples = 0
            healthySamples = 0
            resetResidenceGrowth()
        }
        lastMeasuredSenderAtMs = nowMs
        lastMeasuredSenderStreamId = outbound.streamId
        lastMeasuredSenderCodec = outbound.codec

        // Detect the encoder actually in use, not just the negotiated MIME type.
        // Hardware remains preferred; software fallback must stay usable as well.
        val implementation = outbound.codecImplementation?.lowercase()
        val softwarePath =
            !implementation.isNullOrBlank() &&
                isSoftwareEncoder(implementation)

        /*
         * A complete moving-window sample that identifies a software encoder is
         * sufficient evidence to commit the conservative warm-start pixel rung.
         * The resize happens here, after measurement, never on the touch event.
         */
        if (warmStartResizePending && softwarePath) {
            lastImplementation = implementation
            warmStartResizePending = false
            changedAtMs = nowMs
            pressureSamples = 0
            healthySamples = 0
            resetResidenceGrowth()
            return true
        }

        if (!implementation.isNullOrBlank() && (implementation != lastImplementation || enteringMotion)) {
            lastImplementation = implementation
            if (isSoftwareEncoder(implementation) && shortEdge > 540) {
                shortEdge = 540
                changedAtMs = nowMs
                pressureSamples = 0
                healthySamples = 0
                resetResidenceGrowth()
                return true
            }
        }

        /*
         * Keep the pixel budget aligned with the cadence governor. The host
         * already passes the effective 15/20/24/30/45/60 fps target here.
         * Clamping this layer to 30 fps made 30 fps delivery look healthy
         * during a 45/60 fps trial, so the cheaper pixel lever could fail to
         * react while temporal freshness was still under-delivering.
         *
         * Resolution adapts before cadence: at high cadence we use the real
         * frame budget so pixels are shed early enough to avoid stale queues.
         */
        val goal = targetFps.coerceIn(1, MAX_MOTION_TARGET_FPS)
        val frameMs = 1000.0 / goal
        val encodeMs = sender.processingMs.valid()
        val queueMs = sender.sendQueueMs.valid()
        val received = receiver?.takeIf { it.intervalMs in 500..6000 && it.frames >= 2 }
        val decodeMs = received?.processingMs.valid()
        // Use the receiver's larger actual/target playout residence. A rising
        // WebRTC jitter target is actionable before emitted frames have fully
        // accumulated that delay.
        val jitterMs = received?.playoutDelayMs.valid()
        val underDelivery = sender.fps < goal * 0.85
        val encodePressure = sender.frames >= 2 && underDelivery && (encodeMs ?: 0.0) > frameMs * 0.85
        val queuePressure = (queueMs ?: 0.0) >= 80.0 || (jitterMs ?: 0.0) >= 100.0
        val decodePressure = received != null && (decodeMs ?: 0.0) > frameMs * 0.85 &&
            received.fps < minOf(sender.fps, goal.toDouble()) * 0.85
        val expectedPresentation = minOf(goal.toDouble(), sender.fps, received?.fps ?: 0.0)
        // Held EGL cadence bridges independently phased stats clocks. It may
        // block recovery, but must not become another resolution-pressure vote.
        val presentationPressure = received?.presentationSampleFresh != false &&
            expectedPresentation >= 10.0 && received?.presentedFps?.let {
                it < expectedPresentation * 0.8 || (received.maxRenderGapMs ?: 0) >= 150
            } == true
        val measuredSourceFps = sourceFps.valid()

        /*
         * A real controller gesture is authoritative motion evidence. Do not
         * let a temporarily sparse MediaProjection producer (for example
         * source=3fps during a tap-driven transition) veto freshness policy.
         *
         * Passive/background motion still needs producer evidence so a static
         * screen cannot blur itself merely because the path reports bandwidth
         * limitation.
         */
        val sourceProvesMotion =
            measuredSourceFps?.let { it >= MIN_MOVING_SOURCE_FPS } == true
        val motionEvidence = interactionActive || sourceProvesMotion

        /*
         * Budget the serial motion-to-photon waiting rooms as one deadline
         * instead of waiting for any single layer to cross a large absolute
         * alarm. The values are interval averages, so require a complete
         * measured path and the existing multi-sample pressure hysteresis.
         *
         * At 45/60 Hz this reacts when roughly a few frame periods are already
         * being consumed by encode + sender residence + receiver playout +
         * decode. Keep the signal disabled below the high-cadence ladder:
         * 30 Hz network/jitter pressure already has established cadence relief,
         * and must not unlock the 240px emergency codec-resolution rung by
         * itself.
         */
        val pipelineDeadlineMs =
            if (
                motionEvidence &&
                encodeMs != null &&
                queueMs != null &&
                received != null &&
                jitterMs != null &&
                decodeMs != null
            ) {
                encodeMs + queueMs + jitterMs + decodeMs
            } else {
                null
            }
        val pipelineDeadlinePressureThresholdMs =
            maxOf(
                MIN_PIPELINE_DEADLINE_PRESSURE_MS,
                frameMs * PIPELINE_DEADLINE_BUDGET_MULTIPLIER
            )
        val pipelineDeadlinePressure =
            goal >= HIGH_CADENCE_FPS &&
                pipelineDeadlineMs?.let {
                    it >= pipelineDeadlinePressureThresholdMs
                } == true

        /*
         * Absolute queue thresholds are necessarily reactive. For interactive
         * remoting, three fresh telemetry points can tell us sooner that media
         * residence is climbing toward visible staleness. Track the slope of
         * sender queue + receiver jitter (or sender queue alone when receiver
         * timing is unavailable), normalized by the frame deadline.
         *
         * Active motion is mandatory, the residence composition must remain
         * comparable, and two consecutive rising intervals are required. This
         * adds no stats poll, thread, encoder, queue or frame copy.
         */
        val predictiveResidencePressure =
            observeResidenceGrowth(
                sendQueueMs = queueMs,
                receiverJitterMs = jitterMs,
                receiverMeasured = received != null,
                frameBudgetMs = frameMs,
                motionEvidence = motionEvidence,
                nowMs = nowMs
            )
        val senderLagsMotion =
            if (interactionActive) {
                sender.fps < goal * INTERACTION_DELIVERY_RATIO
            } else {
                measuredSourceFps?.let {
                    sender.fps < minOf(goal.toDouble(), it) * PASSIVE_DELIVERY_RATIO
                } == true
            }
        val bandwidthLimited =
            outbound.qualityLimitationReason.equals("bandwidth", ignoreCase = true)

        /*
         * Predict congestion one control-loop earlier than queue residence.
         * availableOutgoingBitrate comes from WebRTC's own congestion controller
         * (TWCC/REMB depending on the negotiated path). When real motion is
         * present and the estimate cannot comfortably sustain the current pixel
         * rung, spend pixels before the encoder/pacer starts accumulating stale
         * frames. Missing BWE keeps the established reactive behavior unchanged.
         */
        val bandwidthEstimateBps =
            outbound.availableOutgoingBitrateBps.valid()
        val currentRungBitrateBps =
            nominalMotionBitrateBps(shortEdge, goal)
        val bandwidthHeadroomRatio =
            bandwidthEstimateBps?.let { estimate ->
                estimate / currentRungBitrateBps
            }

        /*
         * A bitrate estimate is a path ceiling, not a measurement of current
         * pixel demand. An actively held finger does not prove that the screen
         * producer is generating 30/60 distinct pictures every second. In a
         * static or capture-starved interval (source=1fps, queue=0ms), applying
         * the full motion bitrate model would downshift 360 -> 240 -> 180 even
         * though reducing pixels cannot create the absent source frames.
         *
         * Require either measured natural producer activity or an explicitly
         * unknown producer with independently measured sender activity. Genuine
         * codec/queue/decode pressure below is never vetoed by sparse source
         * telemetry, and active gestures still retain their cadence floor.
         */
        val bandwidthDemandProven =
            sourceProvesMotion ||
                (
                    interactionActive &&
                        measuredSourceFps == null &&
                        sender.fps >= MIN_MOVING_SOURCE_FPS
                    )
        val predictiveBandwidthPressure =
            bandwidthDemandProven &&
                bandwidthHeadroomRatio?.let {
                    it < BWE_PRESSURE_HEADROOM_RATIO
                } == true
        val severePredictiveBandwidthPressure =
            bandwidthDemandProven &&
                bandwidthHeadroomRatio?.let {
                    it < BWE_SEVERE_HEADROOM_RATIO
                } == true

        /*
         * libwebrtc often labels a stream "bandwidth" while its rate estimator
         * simply sits below the configured bitrate ceiling. Requested FPS minus
         * encoded FPS is not packet loss: the capture producer may have supplied
         * only one new frame. Before spending pixels, corroborate the label with
         * producer > sender throughput, rising RTP residence, or actual
         * transport loss/RTT. An overloaded encoder and jitter queue are handled
         * independently above; no extra state machine or media buffer is added.
         */
        val producerOutrunsSender =
            measuredSourceFps?.let { supply ->
                supply >= MIN_MOVING_SOURCE_FPS &&
                    sender.fps < minOf(goal.toDouble(), supply) *
                        PASSIVE_DELIVERY_RATIO
            } == true
        val transportProvesCongestion =
            (queueMs ?: 0.0) >= NETWORK_QUEUE_PRESSURE_MS ||
                (outbound.packetLossRatio ?: 0.0) >= PROVEN_NETWORK_LOSS_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= PROVEN_NETWORK_RTT_MS
        val bandwidthUnderDelivery =
            motionEvidence && senderLagsMotion && bandwidthLimited &&
                (producerOutrunsSender || transportProvesCongestion)
        val bandwidthFreshnessPressure =
            bandwidthUnderDelivery &&
                (
                    (queueMs ?: 0.0) >= NETWORK_QUEUE_PRESSURE_MS ||
                        sender.fps < goal * 0.60
                )
        val severeBandwidthFreshnessPressure =
            bandwidthUnderDelivery &&
                (
                    (queueMs ?: 0.0) >= SEVERE_NETWORK_QUEUE_MS ||
                        sender.fps < goal * 0.45
                )
        if (bandwidthFreshnessPressure || predictiveBandwidthPressure) {
            lastBandwidthPressureAtMs = nowMs
        }
        val pressured =
            encodePressure ||
                queuePressure ||
                decodePressure ||
                presentationPressure ||
                bandwidthUnderDelivery ||
                predictiveBandwidthPressure ||
                predictiveResidencePressure ||
                pipelineDeadlinePressure ||
                outbound.qualityLimitationReason == "cpu"

        /*
         * Use exactly the same rung selection for a validated warm-start commit
         * and for ordinary later pressure relief. This prevents duplicate policy
         * trees from drifting apart.
         */
        fun nextPressureRung(): Int =
            when {
                shortEdge > 540 -> 540
                shortEdge > 360 -> 360
                shortEdge > 240 &&
                    (
                        encodePressure ||
                            decodePressure ||
                            bandwidthFreshnessPressure ||
                            predictiveBandwidthPressure ||
                            predictiveResidencePressure ||
                            pipelineDeadlinePressure
                        ) -> 240
                shortEdge > 180 &&
                    (
                        severeBandwidthFreshnessPressure ||
                            severePredictiveBandwidthPressure
                        ) -> 180
                else -> shortEdge
            }

        if (pressured) {
            healthySamples = 0
            pressureSamples++
            val severe = (queueMs ?: 0.0) >= 150.0 ||
                (sender.frames >= 2 && sender.fps <= 10.0 && encodePressure) ||
                severeBandwidthFreshnessPressure

            /*
             * Do not let one ordinary jitter/render sample turn a speculative
             * control budget into a real source resize. Reuse the established
             * confirmation rule: two pressure windows, or an already-strong
             * signal such as severe queue debt / predictive residence growth.
             *
             * Once confirmed, commit the best rung directly. If the evidence
             * already justifies 240px, avoid a 360px reconfiguration followed by
             * another resize one control interval later.
             */
            if (
                warmStartResizePending &&
                (severe || predictiveResidencePressure || pressureSamples >= 2)
            ) {
                warmStartResizePending = false
                val confirmed = nextPressureRung()
                if (confirmed != shortEdge) {
                    shortEdge = confirmed
                }
                changedAtMs = nowMs
                pressureSamples = 0
                resetResidenceGrowth()
                return true
            }
            /*
             * A 45/60 Hz stream has a 22.2/16.7 ms frame budget. If two
             * consecutive telemetry windows prove encode/decode/presentation
             * work is missing that budget, waiting the legacy 3 seconds lets
             * obsolete frames accumulate before the cheaper pixel lever acts.
             *
             * Give only proven high-cadence pipeline pressure a faster bounded
             * settle. Generic RTT/jitter still uses the conservative path, and
             * pressureSamples must still persist before any pixel step.
             */
            val highCadencePipelinePressure =
                goal >= HIGH_CADENCE_FPS &&
                    (
                        encodePressure ||
                            decodePressure ||
                            presentationPressure ||
                            pipelineDeadlinePressure
                        )
            val settleMs = when {
                severeBandwidthFreshnessPressure ->
                    BANDWIDTH_FAST_SETTLE_MS
                predictiveBandwidthPressure ->
                    BWE_PREDICTIVE_SETTLE_MS
                predictiveResidencePressure ->
                    RESIDENCE_GROWTH_FAST_SETTLE_MS
                highCadencePipelinePressure ->
                    HIGH_CADENCE_FAST_SETTLE_MS
                else ->
                    SETTLE_MS
            }
            /*
             * predictiveResidencePressure already means two comparable rising
             * intervals were observed. Do not require two more generic pressure
             * windows after that proof; the normal settle timer still prevents
             * rapid successive resolution changes.
             */
            if (
                (severe || predictiveResidencePressure || pressureSamples >= 2) &&
                nowMs - changedAtMs >= settleMs
            ) {
                // When a moving source is bandwidth-limited, spend
                // pixels before sacrificing temporal motion. The 180 rung
                // remains reserved for strong bandwidth proof.
                val next = nextPressureRung()
                if (next != shortEdge) {
                    shortEdge = next
                    changedAtMs = nowMs
                    resetResidenceGrowth()
                }
                pressureSamples = 0
            }
        } else {
            pressureSamples = 0
            // A clean RTT or a reduced 15 fps cap is not proof that larger frames fit.
            val receiverHealthy = if (received == null) {
                receiver == null && outbound.qualityLimitationReason == "none" &&
                    outbound.roundTripTimeMs?.let { it in 0..300 } == true
            } else {
                decodeMs != null && decodeMs < frameMs * 0.55 &&
                    jitterMs != null && jitterMs < 40.0 && received.fps >= goal * 0.9 &&
                    (received.dropped ?: 0) == 0 && (received.freezes ?: 0) == 0 &&
                    (received.presentedFps?.let { it >= goal * 0.9 } ?: true) &&
                    (received.maxRenderGapMs ?: 0) < 100
            }
            val nextRecoveryRung =
                when {
                    shortEdge < 240 -> 240
                    shortEdge < 360 -> 360
                    shortEdge < 540 -> 540
                    else -> 720
                }
            val recoveryBandwidthHealthy =
                bandwidthEstimateBps?.let { estimate ->
                    estimate >=
                        nominalMotionBitrateBps(nextRecoveryRung, goal) *
                        BWE_RECOVERY_HEADROOM_RATIO
                } ?: true
            val healthy =
                sender.fps >= goal * 0.9 &&
                    encodeMs != null &&
                    encodeMs < frameMs * 0.5 &&
                    queueMs != null &&
                    queueMs < 20.0 &&
                    receiverHealthy &&
                    recoveryBandwidthHealthy &&
                    (outbound.packetLossRatio ?: 0.0) < 0.025
            // A cadence trial must measure one variable at a time. Pressure
            // relief stays enabled, but do not also enlarge trial frames.
            healthySamples = if (healthy && allowResolutionRecovery) healthySamples + 1 else 0
            if (healthySamples >= 12 && nowMs - changedAtMs >= 12_000L && shortEdge < 720) {
                shortEdge = when { shortEdge < 360 -> 360; shortEdge < 540 -> 540; else -> 720 }
                changedAtMs = nowMs
                healthySamples = 0
                resetResidenceGrowth()
            }
        }
        return before != Triple(
                shortEdge,
                holdingResolution,
                warmStartResizePending
            )
    }

    fun apply(profile: CaptureProfile, motionActive: Boolean): CaptureProfile {
        if (!motionActive && !holdingResolution) return profile

        /*
         * Keep source geometry stable during the unvalidated warm-start window.
         * shortEdge is still allowed to cap bitrate/cadence immediately; only
         * the dimension actuator waits for measured moving-window evidence.
         */
        val sourceShortEdge =
            if (warmStartResizePending) {
                preMotionShortEdge
            } else {
                shortEdge
            }
        val edge = minOf(profile.captureWidthPx, profile.captureHeightPx)
        if (edge <= sourceShortEdge) return profile
        val scale = sourceShortEdge.toDouble() / edge
        fun even(value: Int) = ((value * scale).roundToInt() / 2 * 2).coerceAtLeast(2)
        return profile.copy(
            captureWidthPx = even(profile.captureWidthPx),
            captureHeightPx = even(profile.captureHeightPx)
        )
    }

    fun cadenceFloor(
        profile: CaptureProfile,
        motionActive: Boolean,
        nowMs: Long,
        interactionActive: Boolean = false
    ): Int {
        if (!motionActive) return 1

        /*
         * Finger/control activity is the strongest motion signal in a remote
         * control session. Keep the source ceiling at >=24 fps while the
         * controller is actively interacting; libwebrtc may still drop/adapt
         * frames under congestion, and truly severe loss/RTT can bypass this
         * floor in VideoCadenceGovernor. This prevents the 24 -> 20 -> 15
         * collapse seen while commands are visibly changing the remote UI.
         */
        if (interactionActive) {
            return minOf(BANDWIDTH_CADENCE_FLOOR_FPS, profile.motionFps)
        }

        // Keep at least 24 fps while a recent bandwidth-limited moving source
        // still has a cheaper pixel rung available. This is the Java-side
        // counterpart of MAINTAIN_FRAMERATE: do not hard-cap the source to 15
        // fps while 360/240-wide frames are still clogging the pacer.
        val bandwidthReliefActive =
            nowMs - lastBandwidthPressureAtMs in 0L..BANDWIDTH_PRESSURE_HOLD_MS
        if (bandwidthReliefActive && shortEdge > MIN_BANDWIDTH_SHORT_EDGE) {
            return minOf(BANDWIDTH_CADENCE_FLOOR_FPS, profile.motionFps)
        }

        // After every actual pixel step, give the new frame size a short window
        // to drain the old queue before cadence is allowed to fall. Once the
        // 180-wide emergency rung has settled, cadence may still step down if
        // the path genuinely cannot sustain fresh frames.
        return if (nowMs - changedAtMs < SETTLE_MS) minOf(30, profile.motionFps) else 1
    }

    fun bitrateCeiling(
        profile: CaptureProfile,
        motionActive: Boolean,
        targetFps: Int = BASELINE_MOTION_FPS
    ): Int {
        if (!motionActive && !holdingResolution) return profile.maxVideoBitrateBps

        /*
         * maxBitrateBps is only a ceiling; GCC still decides the actual send
         * rate. Let higher cadence use proportionally more headroom on reduced
         * pixel rungs so the predictor and actuator describe the same operating
         * point instead of predicting 360@60 against 1.8 Mbps while hard-capping
         * the sender at the old 900 kbps 30-fps ceiling.
         */
        val motionCeiling =
            if (shortEdge <= 540) {
                nominalMotionBitrateBps(shortEdge, targetFps)
                    .roundToInt()
            } else {
                profile.maxVideoBitrateBps
            }
        return minOf(profile.maxVideoBitrateBps, motionCeiling)
    }

    /**
     * Decide whether entering motion can keep the encoder's current resolution.
     *
     * The evidence is intentionally strict and quiet-only: one clean hardware
     * encode sample, low RTT/loss/queue and WebRTC's own available-outgoing
     * bitrate estimate. If any proof is missing we retain the existing safe
     * 360-pixel warm start.
     */
    private fun motionWarmStartShortEdge(
        profile: CaptureProfile,
        evidence: VideoHealthSnapshot?,
        targetFps: Int
    ): Int {
        val profileShortEdge =
            minOf(profile.captureWidthPx, profile.captureHeightPx)
        if (profileShortEdge <= MOTION_WARM_START_SHORT_EDGE) {
            return profileShortEdge
        }

        val snapshot = evidence ?: return MOTION_WARM_START_SHORT_EDGE
        val sender = snapshot.recent ?: return MOTION_WARM_START_SHORT_EDGE
        val implementation =
            snapshot.codecImplementation
                ?.lowercase()
                ?.takeIf(String::isNotBlank)
                ?: return MOTION_WARM_START_SHORT_EDGE

        if (
            isSoftwareEncoder(implementation) ||
            sender.intervalMs !in 500..6000 ||
            sender.frames !in 1..MAX_WARM_START_QUIET_FRAMES ||
            sender.processingMs.valid()?.let {
                it <= WARM_START_MAX_ENCODE_MS
            } != true ||
            (sender.sendQueueMs.valid() ?: 0.0) > WARM_START_MAX_QUEUE_MS ||
            snapshot.qualityLimitationReason?.let {
                !it.equals("none", ignoreCase = true)
            } == true ||
            snapshot.roundTripTimeMs?.let {
                it in 0..WARM_START_MAX_RTT_MS
            } != true ||
            (snapshot.packetLossRatio ?: 0.0) >= WARM_START_MAX_LOSS_RATIO
        ) {
            return MOTION_WARM_START_SHORT_EDGE
        }

        val bandwidth =
            snapshot.availableOutgoingBitrateBps.valid()
                ?: return MOTION_WARM_START_SHORT_EDGE

        fun rungFits(edge: Int): Boolean {
            /*
             * Warm-start admission budgets the motion cadence we are about to
             * request, not the quiet sample's 1-2 fps cadence. Otherwise a path
             * that is fine for 720p@30 can be misclassified as safe for
             * 720p@60 and build stale pacer residence immediately on touch.
             */
            val requiredBitrate =
                nominalMotionBitrateBps(
                    edge = edge,
                    targetFps = targetFps
                )
            return profileShortEdge >= edge &&
                profile.maxVideoBitrateBps.toDouble() >= requiredBitrate &&
                bandwidth >=
                    requiredBitrate *
                    WARM_START_BWE_HEADROOM_RATIO
        }

        return when {
            rungFits(NATIVE_WARM_START_SHORT_EDGE) ->
                NATIVE_WARM_START_SHORT_EDGE
            rungFits(MID_WARM_START_SHORT_EDGE) ->
                MID_WARM_START_SHORT_EDGE
            else ->
                MOTION_WARM_START_SHORT_EDGE
        }
    }

    private fun observeResidenceGrowth(
        sendQueueMs: Double?,
        receiverJitterMs: Double?,
        receiverMeasured: Boolean,
        frameBudgetMs: Double,
        motionEvidence: Boolean,
        nowMs: Long
    ): Boolean {
        val queue = sendQueueMs.valid()
        if (!motionEvidence || queue == null || nowMs < 0L) {
            resetResidenceGrowth()
            return false
        }

        val jitter = receiverJitterMs.valid()
        val usesReceiver = receiverMeasured && jitter != null
        val residenceMs = queue + if (usesReceiver) jitter!! else 0.0
        val previous = previousResidenceMs
        val previousAt = previousResidenceAtMs
        val comparable =
            previous != null &&
                previousResidenceUsesReceiver == usesReceiver

        previousResidenceMs = residenceMs
        previousResidenceAtMs = nowMs
        previousResidenceUsesReceiver = usesReceiver

        if (!comparable) {
            residenceGrowthSamples = 0
            return false
        }

        val intervalMs = nowMs - previousAt
        if (intervalMs !in MIN_RESIDENCE_SAMPLE_INTERVAL_MS..MAX_RESIDENCE_SAMPLE_INTERVAL_MS) {
            residenceGrowthSamples = 0
            return false
        }

        val minimumResidenceMs =
            maxOf(
                MIN_RESIDENCE_GROWTH_BASE_MS,
                frameBudgetMs * RESIDENCE_GROWTH_MIN_BUDGET_MULTIPLIER
            )
        val minimumGrowthRateMsPerSecond =
            maxOf(
                MIN_RESIDENCE_GROWTH_RATE_MS_PER_SECOND,
                frameBudgetMs * RESIDENCE_GROWTH_RATE_BUDGET_MULTIPLIER
            )
        val growthRateMsPerSecond =
            (residenceMs - previous!!) * 1_000.0 / intervalMs.toDouble()
        val rising =
            residenceMs >= minimumResidenceMs &&
                growthRateMsPerSecond >= minimumGrowthRateMsPerSecond

        residenceGrowthSamples =
            if (rising) {
                (residenceGrowthSamples + 1).coerceAtMost(
                    RESIDENCE_GROWTH_SAMPLES_REQUIRED
                )
            } else {
                0
            }

        return residenceGrowthSamples >= RESIDENCE_GROWTH_SAMPLES_REQUIRED
    }

    private fun resetResidenceGrowth() {
        previousResidenceMs = null
        previousResidenceAtMs = Long.MIN_VALUE / 2
        previousResidenceUsesReceiver = false
        residenceGrowthSamples = 0
    }

    private fun isSoftwareEncoder(
        implementation: String
    ): Boolean =
        SOFTWARE_ENCODER_MARKERS.any(implementation::contains)

    private fun Double?.valid(): Double? =
        this?.takeIf { it.isFinite() && it >= 0.0 }

    /**
     * First-order bandwidth budget for moving screen content.
     *
     * Resolution-only budgeting is insufficient for remoting: doubling cadence
     * doubles the frame deadlines that must cross encoder + pacer without
     * accumulating stale residence. Scale the established 30 fps rung budgets
     * by requested cadence. This remains only an early predictor; libwebrtc
     * GCC/TWCC stays authoritative for actual bitrate and packet pacing.
     */
    private fun nominalMotionBitrateBps(
        edge: Int,
        targetFps: Int = BASELINE_MOTION_FPS
    ): Double {
        val baseline =
            when {
                edge <= 180 -> 350_000.0
                edge <= 240 -> 500_000.0
                edge <= 360 -> 900_000.0
                edge <= 540 -> 1_800_000.0
                else -> 3_200_000.0
            }
        val cadenceScale =
            targetFps
                .coerceIn(MIN_PREDICTIVE_FPS, MAX_MOTION_TARGET_FPS)
                .toDouble() /
                BASELINE_MOTION_FPS.toDouble()
        return baseline * cadenceScale
    }

    private companion object {
        const val MAX_MOTION_TARGET_FPS = 60
        const val BASELINE_MOTION_FPS = 30
        const val MIN_PREDICTIVE_FPS = 15
        const val MOTION_WARM_START_SHORT_EDGE = 360
        const val MID_WARM_START_SHORT_EDGE = 540
        const val NATIVE_WARM_START_SHORT_EDGE = 720
        const val MAX_WARM_START_QUIET_FRAMES = 3
        const val WARM_START_MAX_ENCODE_MS = 8.0
        const val WARM_START_MAX_QUEUE_MS = 15.0
        const val WARM_START_MAX_RTT_MS = 250
        const val WARM_START_MAX_LOSS_RATIO = 0.02
        const val WARM_START_BWE_HEADROOM_RATIO = 1.25
        val SOFTWARE_ENCODER_MARKERS =
            arrayOf("libvpx", "libaom", "openh264", "software")
        const val SETTLE_MS = 3_000L
        // Follow the same 6-second validity ceiling as VideoHealthWindowTracker.
        const val MAX_SENDER_SAMPLE_GAP_MS = 6_000L
        const val BANDWIDTH_FAST_SETTLE_MS = 1_000L
        const val BWE_PREDICTIVE_SETTLE_MS = 1_000L
        const val BWE_PRESSURE_HEADROOM_RATIO = 1.10
        const val BWE_SEVERE_HEADROOM_RATIO = 0.60
        const val BWE_RECOVERY_HEADROOM_RATIO = 1.20

        /*
         * Rising media residence is predictive, not an emergency. Scale both
         * the minimum debt and its growth rate with frame duration: 60 Hz reacts
         * sooner, while 30 Hz gets a wider budget. Two comparable intervals are
         * required before pixel relief can fire.
         */
        const val MIN_RESIDENCE_GROWTH_BASE_MS = 20.0
        const val RESIDENCE_GROWTH_MIN_BUDGET_MULTIPLIER = 1.25
        const val MIN_RESIDENCE_GROWTH_RATE_MS_PER_SECOND = 12.0
        const val RESIDENCE_GROWTH_RATE_BUDGET_MULTIPLIER = 0.75
        const val RESIDENCE_GROWTH_SAMPLES_REQUIRED = 2
        const val MIN_RESIDENCE_SAMPLE_INTERVAL_MS = 250L
        const val MAX_RESIDENCE_SAMPLE_INTERVAL_MS = 2_500L
        const val RESIDENCE_GROWTH_FAST_SETTLE_MS = 1_000L

        /*
         * Cross-layer motion-to-photon debt. Keep a small absolute floor so
         * noisy sub-frame timing never triggers relief; otherwise scale with
         * the requested frame deadline.
         */
        const val MIN_PIPELINE_DEADLINE_PRESSURE_MS = 45.0
        const val PIPELINE_DEADLINE_BUDGET_MULTIPLIER = 2.5

        const val HIGH_CADENCE_FPS = 45
        const val HIGH_CADENCE_FAST_SETTLE_MS = 1_500L
        const val BANDWIDTH_PRESSURE_HOLD_MS = 2_500L
        const val MIN_MOVING_SOURCE_FPS = 8.0
        const val INTERACTION_DELIVERY_RATIO = 0.75
        const val PASSIVE_DELIVERY_RATIO = 0.75
        const val NETWORK_QUEUE_PRESSURE_MS = 90.0
        const val PROVEN_NETWORK_LOSS_RATIO = 0.06
        const val PROVEN_NETWORK_RTT_MS = 650
        const val SEVERE_NETWORK_QUEUE_MS = 250.0
        const val MIN_BANDWIDTH_SHORT_EDGE = 180
        const val BANDWIDTH_CADENCE_FLOOR_FPS = 24
        const val IDLE_RESTORE_MS = 8_000L
    }
}
