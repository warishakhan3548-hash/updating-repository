package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import kotlin.math.roundToInt

/**
 * Remote control is a detail-sensitive workload: text, forms and icons must
 * remain readable while motion stays fresh. One-second telemetry may reduce
 * the normal spatial envelope through native -> 720 -> 540 -> 360, but 360 is the
 * readability floor for all primary-video adaptation. Once 360 is reached,
 * further overload is paid in temporal cadence/bitrate instead of making
 * text, forms and icons unreadable.
 *
 * WebRTC's BWE clarity guard spends high-cadence excess first when the same
 * admitted pixels still fit at a lower interactive cadence. This avoids
 * turning transient or estimator-only bandwidth pressure into unreadable UI.
 *
 * On Android 12+ the committed spatial envelope is also allowed to resize the
 * MediaProjection VirtualDisplay; older Android versions keep their producer
 * geometry fixed and only adapt the WebRTC output.
 */
internal class MotionVideoBudget {
    var shortEdge = 720
        private set
    private var holdingResolution = false
    private var lastMotionAtMs = Long.MIN_VALUE / 2
    private var changedAtMs = Long.MIN_VALUE / 2
    private var lastMeasuredSenderAtMs = Long.MIN_VALUE / 2
    private var lastSenderIdentity: Triple<String, String?, String?>? = null
    private var pressureSamples = 0
    private var healthySamples = 0
    private var fastRecoverySamples = 0
    private var recoveryInteractionActive = false
    private var interactiveRecoveryTarget = 0
    private var interactiveRecoveryAtMs = Long.MIN_VALUE / 2
    private var interactiveRecoveryCeiling = Int.MAX_VALUE
    private var lastImplementation: String? = null
    private var lastBandwidthPressureAtMs = Long.MIN_VALUE / 2

    /*
     * Entering motion may choose a conservative bitrate/pixel budget before a
     * complete moving-window sample exists. Do not immediately turn that
     * prediction into a VideoSource dimension change: vendor MediaCodec
     * implementations may reconfigure at exactly the first touch/scroll frame.
     *
     * The speculative rung may tighten prediction/cadence admission immediately,
     * but neither source geometry nor its matching sender ceiling moves until
     * measured motion pressure satisfies the existing hysteresis. If motion ends
     * first, the speculative resize is discarded. Measured pressure still
     * receives app-level pixel relief.
     */
    private var warmStartResizePending = false
    private var preMotionShortEdge = 720

    /*
     * Spatial policy has two different states and they must never be conflated:
     *
     * shortEdge is the control-plane budget. It may move speculatively at the
     * first sign of motion so pressure prediction and cadence admission can
     * become conservative immediately. It is NOT the sender/source operating
     * point until measured evidence commits the spatial change.
     *
     * committedSourceShortEdge is the geometry that measured evidence has
     * actually authorized the producer/VideoSource to use. On a native
     * 1080-short-edge phone the historical 720 budget must NOT silently resize
     * the running MediaProjection surface on touch-down. WebRTC hardware
     * encoders reset their codec when the input size changes, so doing that at
     * the first interactive frame creates exactly the hitch this governor is
     * meant to avoid.
     *
     * Int.MAX_VALUE means "no app spatial clamp"; apply() still bounds against
     * the current CaptureProfile.
     */
    private var committedSourceShortEdge = Int.MAX_VALUE

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
     * Observe component boundaries even when an early stats probe has no delta
     * or the host spends this window on cadence instead of pixels. A replacement
     * must establish its own pressure/recovery proof; the committed geometry and
     * safety cooldowns survive. Missing vendor labels do not prove replacement.
     */
    fun onSenderEvidence(outbound: VideoHealthSnapshot) {
        val previousIdentity = lastSenderIdentity
        val sameStream =
            previousIdentity?.first == outbound.streamId &&
                previousIdentity.second == outbound.codec
        val implementation = outbound.codecImplementation
            ?.trim()?.lowercase()?.takeIf(String::isNotEmpty)
            ?: previousIdentity?.third?.takeIf { sameStream }
        val identity = Triple(outbound.streamId, outbound.codec, implementation)
        val componentChanged =
            previousIdentity?.third != null &&
                implementation != null &&
                implementation != previousIdentity.third
        if (previousIdentity != null && (!sameStream || componentChanged)) {
            pressureSamples = 0
            healthySamples = 0
            fastRecoverySamples = 0
            interactiveRecoveryTarget = 0
            interactiveRecoveryCeiling = Int.MAX_VALUE
            resetResidenceGrowth()
            lastMeasuredSenderAtMs = Long.MIN_VALUE / 2
            lastImplementation = null
        }
        lastSenderIdentity = identity
    }

    /**
     * New motion must not blindly pay a MediaCodec resolution restart.
     *
     * Unknown / software / pressured paths may select a conservative
     * 360-short-edge control budget. When the immediately preceding quiet
     * WebRTC sample proves a fast hardware encoder plus real bandwidth
     * headroom, the control budget may preserve 540 or 720 instead.
     *
     * Crucially, a predicted lower rung is not applied to VideoSource geometry
     * or the matching sender bitrate ceiling on touch-down. A real moving-window
     * pressure sample must confirm the spatial operating-point change first.
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
            fastRecoverySamples = 0
            resetResidenceGrowth()
            preMotionShortEdge = shortEdge
            warmStartResizePending = false

            val profileShortEdge =
                minOf(profile.captureWidthPx, profile.captureHeightPx)
            // Before motion the source follows CaptureProfile because
            // holdingResolution was false. Snapshot that real running geometry
            // independently from the speculative control budget.
            committedSourceShortEdge = profileShortEdge
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

    /**
     * Prefer temporal relief before visible blur when WebRTC's own bandwidth
     * estimate says the current high-cadence demand no longer fits, but the
     * SAME admitted source geometry still fits at a >=30 fps interactive rate.
     *
     * This is deliberately only an early-warning lane. Encoder, sender queue,
     * loss/RTT and receiver presentation must still look healthy. Once those
     * stages are already under pressure, the existing spatial ladder remains
     * free to shed pixels immediately. The returned value is only a cadence
     * ceiling suggestion; GCC/TWCC remains authoritative for the actual rate.
     */
    fun clarityPreservingCadenceCeiling(
        profile: CaptureProfile,
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        sourceFps: Double?,
        motionActive: Boolean,
        targetFps: Int,
        interactionActive: Boolean = false
    ): Int? {
        val target =
            targetFps.coerceIn(1, MAX_MOTION_TARGET_FPS)
        if (
            !motionActive ||
            target <= CLARITY_PRESERVING_FPS_FLOOR
        ) {
            return null
        }

        val sender = outbound.recent ?: return null
        val bandwidthEstimateBps =
            outbound.availableOutgoingBitrateBps.valid()
                ?: return null
        val measuredSourceFps =
            sourceFps.valid()
        val movingDemandProven =
            measuredSourceFps?.let {
                it >= MIN_MOVING_SOURCE_FPS
            } == true ||
                (
                    interactionActive &&
                        measuredSourceFps == null &&
                        sender.fps >= MIN_MOVING_SOURCE_FPS
                    )
        if (!movingDemandProven) return null

        /*
         * availableOutgoingBitrate is path capacity, while the completed RTP
         * window is the best measurement of what THIS screen content actually
         * costs. Forms/text can be cheap at 60 fps; games/video can be expensive
         * at the same geometry. Prefer the measured utilization whenever it is
         * present and fall back to the conservative nominal model only on OEM
         * builds that omit usable byte deltas.
         */
        val observedBandwidthUtilization =
            bandwidthUtilization(
                sender = sender,
                bandwidthEstimateBps = bandwidthEstimateBps
            )
        /*
         * Measured RTP demand and the nominal fallback must obey the SAME
         * clarity headroom contract. The fallback path below already reserves
         * 10% via CLARITY_PRESERVING_BWE_HEADROOM_RATIO (1.10). Keeping a
         * separate 78% target / 82% trigger here made better telemetry more
         * conservative than missing telemetry: a fully delivered stream around
         * 85% utilization could be downshifted despite zero queue or glass debt.
         *
         * Derive the measured threshold from the existing headroom constant so
         * both paths cannot silently drift apart again. Reactive queue/loss/
         * decode/presentation pressure remains independently authoritative.
         */
        val measuredTargetUtilization =
            1.0 / CLARITY_PRESERVING_BWE_HEADROOM_RATIO
        if (
            observedBandwidthUtilization != null &&
            observedBandwidthUtilization <= measuredTargetUtilization
        ) {
            return null
        }

        /*
         * This lane exists only before a real backlog forms. If codec,
         * pacer/network residence, loss/RTT or controller decode/glass already
         * shows material pressure, pixel relief is allowed to remain the faster
         * safety valve.
         */
        val frameMs = 1_000.0 / target
        val encodeMs =
            sender.processingMs.valid()
                ?: return null
        val queueMs =
            sender.sendQueueMs.valid()
                ?: return null
        if (
            encodeMs > frameMs * CLARITY_PRESERVING_CODEC_BUDGET_RATIO ||
            queueMs >= CLARITY_PRESERVING_MAX_QUEUE_MS ||
            outbound.qualityLimitationReason.equals(
                "cpu",
                ignoreCase = true
            ) ||
            outbound.roundTripTimeMs?.let {
                it >= CLARITY_PRESERVING_MAX_RTT_MS
            } == true ||
            outbound.packetLossRatio?.let {
                it >= CLARITY_PRESERVING_MAX_LOSS_RATIO
            } == true
        ) {
            return null
        }

        receiver
            ?.takeIf { it.frames >= 2 }
            ?.let { window ->
                if (
                    window.processingMs.valid()?.let {
                        it > frameMs *
                            CLARITY_PRESERVING_CODEC_BUDGET_RATIO
                    } == true ||
                    window.jitterMs.valid()?.let {
                        it >= CLARITY_PRESERVING_MAX_JITTER_MS
                    } == true ||
                    (window.dropped ?: 0) > 0 ||
                    (window.freezes ?: 0) > 0 ||
                    (window.maxRenderGapMs ?: 0) >=
                        CLARITY_PRESERVING_MAX_RENDER_GAP_MS
                ) {
                    return null
                }
            }

        /*
         * When real RTP demand is known, solve the temporal relief directly
         * from measured bits/sec instead of a fixed resolution table. The
         * target keeps a bounded capacity reserve for key-frame/UI bursts.
         *
         * Example: a cheap 60 fps form using 2.8 Mbps on a 5 Mbps path keeps
         * 60 fps; a complex 60 fps scene using 4.5 Mbps gets a modest cadence
         * trim while preserving pixels. If even the >=30 fps floor cannot be
         * protected, fall through to spatial relief.
         */
        observedBandwidthUtilization?.let { utilization ->
            val measuredSenderFps =
                sender.fps
                    .takeIf {
                        it.isFinite() &&
                            it >= MIN_MOVING_SOURCE_FPS
                    }
                    ?: return null
            val sustainableFps =
                (
                    measuredSenderFps *
                        measuredTargetUtilization /
                        utilization
                    )
                    .toInt()

            if (sustainableFps >= target) {
                return null
            }
            if (sustainableFps < CLARITY_PRESERVING_FPS_FLOOR) {
                return null
            }
            return sustainableFps.coerceIn(
                CLARITY_PRESERVING_FPS_FLOOR,
                target - 1
            )
        }

        /*
         * Legacy/fallback path for platforms where interval RTP bitrate is not
         * available. Budget the geometry actually admitted to the encoder, not
         * a speculative control-plane rung.
         */
        val admittedShortEdge =
            admittedSourceShortEdge(profile)
        val currentDemandBps =
            nominalMotionBitrateBps(
                admittedShortEdge,
                target
            )
        if (
            bandwidthEstimateBps >=
            currentDemandBps * BWE_PRESSURE_HEADROOM_RATIO
        ) {
            return null
        }

        val floorDemandBps =
            nominalMotionBitrateBps(
                admittedShortEdge,
                CLARITY_PRESERVING_FPS_FLOOR
            )
        val protectedFloorBps =
            floorDemandBps *
                CLARITY_PRESERVING_BWE_HEADROOM_RATIO
        if (bandwidthEstimateBps < protectedFloorBps) {
            return null
        }

        return (
            CLARITY_PRESERVING_FPS_FLOOR.toDouble() *
                bandwidthEstimateBps /
                protectedFloorBps
            )
            .toInt()
            .coerceIn(
                CLARITY_PRESERVING_FPS_FLOOR,
                target - 1
            )
    }

    /**
     * Route proven LOCAL pixel-processing pressure to one explicit spatial rung
     * before the cadence governor halves a high-cadence stream.
     *
     * This is intentionally narrow. Bandwidth/jitter pressure remains
     * cadence-first so forms/text keep their pixels. Encoder, decoder or
     * MediaProjection pressure on an otherwise clean path is different: reducing
     * 60 -> 30 fps does not remove the per-frame pixel cost that caused the
     * overload and is directly visible as gaming-style judder. When there is
     * still a >540px rung to spend, one measured source-size step is the cheaper
     * freshness repair.
     *
     * The method is pure and uses the same hard evidence as observe(); it never
     * changes geometry by itself. HostWebRtcSession uses it only to decide which
     * existing actuator gets first refusal for the current health window.
     */
    fun prefersSpatialReliefBeforeCadence(
        profile: CaptureProfile,
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        sourceFps: Double?,
        sourceMaxGapMs: Double?,
        motionActive: Boolean,
        targetFps: Int,
        interactionActive: Boolean = false,
        sourceMotionActive: Boolean = false,
        interactionCaptureStarved: Boolean = false,
        canResizeProducerSurface: Boolean = false
    ): Boolean {
        if (!motionActive || targetFps < HIGH_CADENCE_FPS) return false

        /*
         * Never trade the last high-detail rung for cadence. At <=540p the
         * temporal governor owns relief unless observe() later sees a genuinely
         * severe/emergency condition.
         */
        if (
            admittedSourceShortEdge(profile) <=
                DETAIL_CLARITY_FLOOR_SHORT_EDGE
        ) {
            return false
        }

        val sender =
            outbound.recent
                ?.takeIf {
                    it.intervalMs in 500..6000 &&
                        it.frames >= 2
                }
                ?: return false
        val received =
            receiver
                ?.takeIf {
                    it.intervalMs in 500..6000 &&
                        it.frames >= 2
                }
                ?: return false

        val goal =
            targetFps.coerceIn(
                1,
                MAX_MOTION_TARGET_FPS
            )
        val frameMs = 1_000.0 / goal
        val encodeMs = sender.processingMs.valid()
        val decodeMs = received.processingMs.valid()
        val queueMs = sender.sendQueueMs.valid()
        val jitterMs = received.playoutDelayMs.valid()

        /*
         * Spatial-first is a LOCAL-compute lane, not a congestion heuristic.
         * Require the measured transport path to be quiet enough that changing
         * pixels is actually aimed at codec/capture work rather than masking a
         * network problem.
         */
        val transportClean =
            !outbound.qualityLimitationReason
                .equals("bandwidth", ignoreCase = true) &&
                queueMs?.let {
                    it < CLARITY_PRESERVING_MAX_QUEUE_MS
                } == true &&
                jitterMs?.let {
                    it < CLARITY_PRESERVING_MAX_JITTER_MS
                } == true &&
                outbound.roundTripTimeMs?.let {
                    it <= CLARITY_PRESERVING_MAX_RTT_MS
                } != false &&
                (outbound.packetLossRatio ?: 0.0) <
                CLARITY_PRESERVING_MAX_LOSS_RATIO

        if (!transportClean) return false

        /*
         * Match observe()'s measured codec-pressure contract exactly. A generic
         * "cpu" label alone is still insufficient: real encode/decode service
         * time must be missing the active frame deadline.
         */
        val encoderComputePressure =
            sender.fps < goal * 0.85 &&
                encodeMs?.let {
                    it > frameMs * 0.85
                } == true
        val decoderComputePressure =
            decodeMs?.let {
                it > frameMs * 0.85
            } == true &&
                received.fps <
                minOf(
                    sender.fps,
                    goal.toDouble()
                ) * 0.85

        val measuredSourceFps = sourceFps.valid()
        val producerGapThresholdMs =
            maxOf(
                MIN_PRODUCER_STALL_GAP_MS,
                frameMs * PRODUCER_STALL_FRAME_MULTIPLIER
            )
        val causalInteractionMotionEvidence =
            interactionActive &&
                interactionCaptureStarved &&
                measuredSourceFps?.let {
                    it >= MIN_CAUSAL_INTERACTION_SOURCE_FPS
                } == true
        val producerMotionEvidence =
            sourceMotionActive ||
                causalInteractionMotionEvidence
        val lowCadenceProducerStarvation =
            measuredSourceFps?.let { measured ->
                measured < MIN_MOVING_SOURCE_FPS &&
                    (
                        (
                            sourceMotionActive &&
                                measured >= MIN_PRODUCER_STARVATION_FPS
                            ) ||
                            (
                                causalInteractionMotionEvidence &&
                                    measured >=
                                    MIN_CAUSAL_INTERACTION_SOURCE_FPS
                                )
                        )
            } == true
        val producerPressure =
            canResizeProducerSurface &&
                producerMotionEvidence &&
                (
                    lowCadenceProducerStarvation ||
                        sourceMaxGapMs.valid()?.let {
                            it >= producerGapThresholdMs
                        } == true
                    )

        return encoderComputePressure ||
            decoderComputePressure ||
            producerPressure
    }

    fun observe(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        sourceFps: Double?,
        motionActive: Boolean,
        targetFps: Int,
        nowMs: Long,
        interactionActive: Boolean = false,
        allowResolutionRecovery: Boolean = true,
        sourceMaxGapMs: Double? = null,
        sourceMotionActive: Boolean = false,
        interactionCaptureStarved: Boolean = false,
        canResizeProducerSurface: Boolean = false,
        profile: CaptureProfile? = null,
        allowSpatialRelief: Boolean = true,
        minimumSpatialShortEdge: Int = CLARITY_FLOOR_SHORT_EDGE
    ): Boolean {
        onSenderEvidence(outbound)
        // Ordinary clean votes must not become a touch-down resize, and held
        // gesture proof must not carry into the ordinary conservative lane.
        if (recoveryInteractionActive != interactionActive) {
            healthySamples = 0
            fastRecoverySamples = 0
            recoveryInteractionActive = interactionActive
            interactiveRecoveryTarget = 0
            interactiveRecoveryCeiling = Int.MAX_VALUE
        }
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
            fastRecoverySamples = 0
            resetResidenceGrowth()
            if (nowMs - lastMotionAtMs >= IDLE_RESTORE_MS) {
                lastBandwidthPressureAtMs = Long.MIN_VALUE / 2
                holdingResolution = false
                shortEdge = 720
                committedSourceShortEdge = Int.MAX_VALUE
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
        if (sender == null) {
            // Short getStats probes do not have a complete sender interval.
            // Ignore them instead of erasing validated congestion evidence.
            // Fast clarity recovery is deliberately stricter: a missing full
            // sender window breaks the consecutive proof needed for an upshift.
            fastRecoverySamples = 0
            // Expire ordinary pressure evidence on the next complete sample
            // after a long gap.
            return before != Triple(
            shortEdge,
            holdingResolution,
            warmStartResizePending
        )
        }
        if (nowMs - lastMeasuredSenderAtMs !in 0L..MAX_SENDER_SAMPLE_GAP_MS) {
            pressureSamples = 0
            healthySamples = 0
            fastRecoverySamples = 0
            resetResidenceGrowth()
        }
        lastMeasuredSenderAtMs = nowMs

        // Detect the encoder actually in use, not just the negotiated MIME type.
        // Hardware remains preferred; software fallback must stay usable as well.
        val implementation = outbound.codecImplementation
            ?.trim()?.lowercase()?.takeIf(String::isNotEmpty)
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
            committedSourceShortEdge = shortEdge
            changedAtMs = nowMs
            pressureSamples = 0
            healthySamples = 0
            fastRecoverySamples = 0
            resetResidenceGrowth()
            return true
        }

        if (!implementation.isNullOrBlank() && (implementation != lastImplementation || enteringMotion)) {
            lastImplementation = implementation
            if (isSoftwareEncoder(implementation) && shortEdge > 540) {
                shortEdge = 540
                committedSourceShortEdge = shortEdge
                changedAtMs = nowMs
                pressureSamples = 0
                healthySamples = 0
                fastRecoverySamples = 0
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
         * The host spends high-cadence temporal excess before authorizing a
         * source resize. Once spatial relief is eligible, keep using the real
         * frame deadline here so a genuinely overloaded 30-fps operating point
         * can still shed pixels before stale residence grows.
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
        /*
         * qualityLimitationReason="cpu" is deliberately NOT a spatial vote.
         * WebRTC defines it as the most limiting reason for resolution and/or
         * frame rate; with this session's MAINTAIN_RESOLUTION contract the
         * cadence governor owns that generic CPU signal first. Pixels move only
         * when measured encode/queue/decode/deadline evidence below proves that
         * the current geometry itself is missing freshness deadlines.
         *
         * Treating the label alone as pixel pressure made a healthy 60 fps
         * hardware path fall 720 -> 540 -> 360 even with ~5 ms encode and an
         * empty pacer, producing the controller-side "140p" clarity regression.
         */
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
        val measuredSourceMaxGapMs = sourceMaxGapMs.valid()

        /*
         * Receiver/encoder telemetry cannot repair a frame that Android never
         * produced. On Android 12+ the WebRTC screen capturer can resize the
         * existing VirtualDisplay, so a proven moving source that collapses to
         * a few FPS (or develops large producer gaps) may spend pixels at the
         * producer itself.
         *
         * sourceMotionActive is deliberately stricter than interactionActive:
         * it is backed by recent natural MediaProjection timestamps. A finger
         * held on a static form therefore cannot blur the screen merely because
         * no new frames are expected. Older Android versions keep the historic
         * fixed producer geometry because changeCaptureFormat() recreates the
         * VirtualDisplay there.
         */
        val producerGapThresholdMs =
            maxOf(
                MIN_PRODUCER_STALL_GAP_MS,
                frameMs * PRODUCER_STALL_FRAME_MULTIPLIER
            )
        /*
         * PassiveMotionPriority normally proves source motion from >=8 fps
         * natural producer cadence. That proof becomes circular when the
         * MediaProjection producer is already cold-stalled at 2-6 fps: the
         * starvation detector cannot enter because the signal it waits for is
         * itself suppressed by starvation.
         *
         * Applied-input capture probes break that cycle. Repeated forced pulls
         * mean no newer natural texture arrived by the next display opportunity.
         * Combine that causal proof with at least a small amount of genuine
         * producer activity so a completely static form (0-1 fps) still cannot
         * masquerade as a resize-worthy capture failure.
         */
        val causalInteractionMotionEvidence =
            interactionActive &&
                interactionCaptureStarved &&
                measuredSourceFps?.let {
                    it >= MIN_CAUSAL_INTERACTION_SOURCE_FPS
                } == true
        val producerMotionEvidence =
            sourceMotionActive ||
                causalInteractionMotionEvidence
        val lowCadenceProducerStarvation =
            measuredSourceFps?.let { sourceFps ->
                sourceFps < MIN_MOVING_SOURCE_FPS &&
                    (
                        (
                            sourceMotionActive &&
                                sourceFps >= MIN_PRODUCER_STARVATION_FPS
                            ) ||
                            (
                                causalInteractionMotionEvidence &&
                                    sourceFps >=
                                    MIN_CAUSAL_INTERACTION_SOURCE_FPS
                                )
                        )
            } == true
        val producerStarvationPressure =
            canResizeProducerSurface &&
                producerMotionEvidence &&
                (
                    lowCadenceProducerStarvation ||
                        measuredSourceMaxGapMs?.let {
                            it >= producerGapThresholdMs
                        } == true
                    )

        /*
         * Preserve the existing one-window emergency path only for ordinary
         * natural-motion proof. Causal cold-start proof already requires
         * repeated post-input misses, but it still waits for two complete
         * WebRTC health windows before changing VirtualDisplay geometry. That
         * prevents a short tap on a low-motion screen from paying a codec
         * reconfiguration.
         */
        val severeProducerStarvation =
            producerStarvationPressure &&
                sourceMotionActive &&
                (
                    measuredSourceFps?.let {
                        it in 0.0..SEVERE_PRODUCER_STARVATION_FPS
                    } == true ||
                        measuredSourceMaxGapMs?.let {
                            it >= SEVERE_PRODUCER_STALL_GAP_MS
                        } == true
                    )

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
        /*
         * shortEdge may still be the speculative warm-start control rung while
         * MediaProjection/VideoSource/MediaCodec remain at the pre-motion
         * geometry. BWE fallback must budget the pixels actually admitted to
         * the encoder; otherwise a native 720/1080 stream can be costed as
         * 360p until queue debt is already visible.
         */
        val currentRungBitrateBps =
            nominalMotionBitrateBps(
                admittedSourceShortEdge(profile),
                goal
            )
        val bandwidthHeadroomRatio =
            bandwidthEstimateBps?.let { estimate ->
                estimate / currentRungBitrateBps
            }
        val observedBandwidthUtilization =
            bandwidthEstimateBps?.let { estimate ->
                bandwidthUtilization(
                    sender = sender,
                    bandwidthEstimateBps = estimate
                )
            }

        /*
         * A bitrate estimate is a path ceiling, not a measurement of current
         * pixel demand. An actively held finger does not prove that the screen
         * producer is generating 30/60 distinct pictures every second. In a
         * static or capture-starved interval (source=1fps, queue=0ms), applying
         * the motion bitrate model could otherwise downshift readable pixels
         * even though reducing resolution cannot create absent source frames.
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
        /*
         * If byte deltas exist, let actual RTP utilization own predictive BWE
         * relief. This prevents a fixed 720/540 bitrate table from blurring a
         * low-entropy UI that is comfortably below path capacity. The nominal
         * model remains only as a compatibility fallback when stats are absent.
         */
        val predictiveBandwidthPressure =
            bandwidthDemandProven &&
                (
                    observedBandwidthUtilization?.let {
                        it > BWE_PREDICTIVE_PRESSURE_UTILIZATION_RATIO
                    } ?: bandwidthHeadroomRatio?.let {
                        it < BWE_PRESSURE_HEADROOM_RATIO
                    } == true
                    )

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

        /*
         * Average bitrate/loss can look healthy while one oversized screen
         * update creates a short packet train that is repaired by RTX. WebRTC's
         * hugeFramesSent marks frames >=2.5x target size, while RTX/NACK/PLI/FIR
         * proves that the burst actually stressed delivery. Treat only the
         * corroborated combination as pixel pressure: a clean slide/key frame
         * remains legal and never downshifts quality by itself.
         *
         * This closes the gap between the admission-only recovery signal in
         * PhotonFreshnessGovernor and MotionVideoBudget's reactive queue alarms.
         * The cheaper spatial actuator moves first; native GCC/TWCC/RTX remains
         * authoritative and no packet/frame queue is added here.
         */
        val retransmitRatio = sender.retransmitRatio.valid()
        val nackRatePerSecond =
            sender.nacks
                ?.takeIf { it >= 0 && sender.intervalMs > 0 }
                ?.let {
                    it * 1_000.0 /
                        sender.intervalMs.toDouble()
                }
        val repairPressure =
            sender.plis?.let { it > 0 } == true ||
                sender.firs?.let { it > 0 } == true ||
                retransmitRatio
                    ?.let { it >= RTP_BURST_RETRANSMIT_RATIO } == true ||
                nackRatePerSecond
                    ?.let { it >= RTP_BURST_NACK_RATE_PER_SECOND } == true
        /*
         * A spatial transition can itself force an H.264/VP8 key frame. Do not
         * feed that expected transition burst straight back into another resize.
         * Other queue/loss/decode alarms remain active during this guard.
         */
        val rtpBurstWindowEligible =
            nowMs - changedAtMs >= RTP_BURST_POST_SPATIAL_GUARD_MS
        val rtpBurstPressure =
            motionEvidence &&
                rtpBurstWindowEligible &&
                (sender.hugeFrames ?: 0) > 0 &&
                repairPressure

        if (
            bandwidthFreshnessPressure ||
            predictiveBandwidthPressure ||
            rtpBurstPressure
        ) {
            lastBandwidthPressureAtMs = nowMs
        }
        val pressured =
            encodePressure ||
                queuePressure ||
                decodePressure ||
                presentationPressure ||
                bandwidthUnderDelivery ||
                predictiveBandwidthPressure ||
                rtpBurstPressure ||
                predictiveResidencePressure ||
                pipelineDeadlinePressure ||
                producerStarvationPressure

        /*
         * Use exactly the same rung selection for a validated warm-start commit
         * and for ordinary later pressure relief. This prevents duplicate policy
         * trees from drifting apart.
         */
        /*
         * 360 remains the established global readability floor. The caller may
         * raise the floor for ONE already-classified spatial decision (the
         * clean local-compute/high-cadence lane uses 540) without changing the
         * long-standing network, emergency and recovery contracts.
         */
        val currentSourceShortEdge =
            admittedSourceShortEdge(profile)
        val scopedSpatialFloor =
            minimumSpatialShortEdge.coerceIn(
                CLARITY_FLOOR_SHORT_EDGE,
                DETAIL_CLARITY_FLOOR_SHORT_EDGE
            )

        fun nextPressureRung(severePressure: Boolean): Int =
            when {
                /*
                 * Severe producer starvation is an emergency capture-repair
                 * path and is allowed to spend the universal 360 floor.
                 */
                severeProducerStarvation &&
                    shortEdge > CLARITY_FLOOR_SHORT_EDGE ->
                    CLARITY_FLOOR_SHORT_EDGE

                /*
                 * Preserve the existing warm-start contract: if the control
                 * plane already selected a readable budget, commit that exact
                 * budget when pressure proves a real resize is needed. The
                 * scoped floor only prevents the new local-compute lane from
                 * turning that single decision into a <540p clarity collapse.
                 */
                currentSourceShortEdge > shortEdge ->
                    if (severePressure) {
                        shortEdge
                    } else {
                        maxOf(
                            shortEdge,
                            scopedSpatialFloor
                        )
                    }
                shortEdge > NATIVE_WARM_START_SHORT_EDGE ->
                    NATIVE_WARM_START_SHORT_EDGE
                shortEdge > DETAIL_CLARITY_FLOOR_SHORT_EDGE ->
                    maxOf(
                        DETAIL_CLARITY_FLOOR_SHORT_EDGE,
                        scopedSpatialFloor
                    )
                shortEdge > CLARITY_FLOOR_SHORT_EDGE ->
                    if (severePressure) {
                        CLARITY_FLOOR_SHORT_EDGE
                    } else {
                        scopedSpatialFloor
                    }
                else ->
                    shortEdge
            }

        /*
         * A speculative motion warm-start is only a control-plane prediction:
         * the encoder is still receiving the pre-motion/native geometry. Never
         * let the generic recovery ladder turn a healthy native stream into a
         * real 540/360 resize.
         *
         * One completed moving window can safely cancel that prediction when
         * native delivery is on deadline and measured RTP demand still leaves
         * capacity headroom. This performs no source upshift—the source is
         * already there—so it avoids both unnecessary blur and a MediaCodec
         * reconfiguration.
         */
        val warmStartNativeProven =
            warmStartResizePending &&
                !pressured &&
                sourceProvesMotion &&
                sender.fps >= goal * WARM_START_VALIDATION_DELIVERY_RATIO &&
                encodeMs?.let {
                    it < frameMs * WARM_START_VALIDATION_CODEC_BUDGET_RATIO
                } == true &&
                queueMs?.let {
                    it < WARM_START_VALIDATION_MAX_QUEUE_MS
                } == true &&
                outbound.roundTripTimeMs?.let {
                    it in 0..WARM_START_VALIDATION_MAX_RTT_MS
                } == true &&
                (outbound.packetLossRatio ?: 0.0) <
                    WARM_START_VALIDATION_MAX_LOSS_RATIO &&
                observedBandwidthUtilization?.let {
                    it <= WARM_START_VALIDATION_MAX_UTILIZATION_RATIO
                } == true

        if (warmStartNativeProven) {
            shortEdge = preMotionShortEdge
            warmStartResizePending = false
            pressureSamples = 0
            healthySamples = 0
            fastRecoverySamples = 0
            resetResidenceGrowth()
            return true
        }

        /*
         * A source-geometry change is an expensive MediaProjection/VideoSource/
         * MediaCodec operating-point transition. While a 45/60-fps stream still
         * has temporal excess available, let VideoCadenceGovernor spend that
         * cheaper budget first. Do not accumulate hidden spatial votes while
         * the gate is closed: after cadence changes, require fresh telemetry at
         * the new operating point before pixels may move.
         *
         * Severe producer starvation is the exception. On Android 12+ resizing
         * the VirtualDisplay can repair a capture producer that is itself
         * missing frames, so that path remains an immediate spatial escape.
         */
        if (
            pressured &&
            !allowSpatialRelief &&
            !severeProducerStarvation
        ) {
            pressureSamples = 0
            healthySamples = 0
            fastRecoverySamples = 0
            resetResidenceGrowth()
            return false
        }

        if (pressured) {
            healthySamples = 0
            fastRecoverySamples = 0
            pressureSamples++
            val severe = (queueMs ?: 0.0) >= 150.0 ||
                (sender.frames >= 2 && sender.fps <= 10.0 && encodePressure) ||
                severeBandwidthFreshnessPressure ||
                severeProducerStarvation

            /*
             * Do not let one ordinary jitter/render sample turn a speculative
             * control budget into a real source resize. Reuse the established
             * confirmation rule: two pressure windows, or an already-strong
             * signal such as severe queue debt / predictive residence growth.
             *
             * Once confirmed, commit the best readable rung directly. No
             * pressure path is allowed to cross the 360px short-edge floor.
             */
            if (
                warmStartResizePending &&
                (severe || predictiveResidencePressure || pressureSamples >= 2)
            ) {
                // Select while the speculative-warm-start guard is still
                // armed so producer starvation and ordinary pressure share the
                // same single-step readable spatial ladder.
                val confirmed = nextPressureRung(severe)
                onSpatialPressureCommit(confirmed, nowMs)
                warmStartResizePending = false
                if (confirmed != shortEdge) {
                    shortEdge = confirmed
                }
                committedSourceShortEdge = shortEdge
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
                producerStarvationPressure ->
                    PRODUCER_STARVATION_FAST_SETTLE_MS
                predictiveBandwidthPressure ->
                    BWE_PREDICTIVE_SETTLE_MS
                rtpBurstPressure ->
                    RTP_BURST_FAST_SETTLE_MS
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
                // Every pressure class stops at the 360 readability floor.
                // Severe transport failure continues through temporal relief.
                val next = nextPressureRung(severe)
                val sourceCommitNeeded =
                    currentSourceShortEdge > next
                if (next != shortEdge || sourceCommitNeeded) {
                    onSpatialPressureCommit(next, nowMs)
                    shortEdge = next
                    committedSourceShortEdge = shortEdge
                    changedAtMs = nowMs
                    resetResidenceGrowth()
                    pressureSamples = 0
                    return true
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
            val profileRecoveryShortEdge =
                profile?.let {
                    minOf(it.captureWidthPx, it.captureHeightPx)
                } ?: NATIVE_WARM_START_SHORT_EDGE
            val nextRecoveryRung =
                when {
                    shortEdge < CLARITY_FLOOR_SHORT_EDGE ->
                        CLARITY_FLOOR_SHORT_EDGE
                    shortEdge < 540 -> 540
                    shortEdge < NATIVE_WARM_START_SHORT_EDGE ->
                        NATIVE_WARM_START_SHORT_EDGE
                    shortEdge < HD_PLUS_SHORT_EDGE -> HD_PLUS_SHORT_EDGE
                    else -> profileRecoveryShortEdge
                }.coerceAtMost(profileRecoveryShortEdge)
            val currentRecoveryShortEdge =
                admittedSourceShortEdge(profile)
            val recoveringNativeDetail =
                nextRecoveryRung > NATIVE_WARM_START_SHORT_EDGE
            val projectedRecoveryDemandBps =
                projectedRecoveryBitrateBps(
                    sender = sender,
                    currentShortEdge = currentRecoveryShortEdge,
                    nextShortEdge = nextRecoveryRung,
                    targetFps = goal,
                    maxBitrateBps =
                        if (recoveringNativeDetail || interactionActive) {
                            // Native and interactive probes must not hide
                            // demand above the profile's own bitrate ceiling.
                            Int.MAX_VALUE
                        } else {
                            profile?.maxVideoBitrateBps ?: Int.MAX_VALUE
                        }
                )
            val nextRecoveryBitrateBps =
                projectedRecoveryDemandBps ?: nominalMotionBitrateBps(
                    nextRecoveryRung,
                    goal
                )
            val recoveryBandwidthHealthy =
                bandwidthEstimateBps?.let { estimate ->
                    estimate >=
                        nextRecoveryBitrateBps *
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

            /*
             * The conservative recovery path intentionally avoids oscillation,
             * but twelve clean ~1 s windows for every upshift can keep a
             * controller visibly blurry for 12-36 seconds after a transient
             * Wi-Fi/cellular dip has already cleared.
             *
             * Add a faster one-rung capacity probe only when ALL layers prove
             * headroom at once: WebRTC BWE, sender queue/encode, RTT/loss,
             * receiver decode/jitter and real controller presentation. Missing
             * BWE or missing glass proof can never use this path. Recovery to
             * >=720 is deliberately harder than readability recovery to 360/540.
             *
             * This never forces bandwidth. GCC/TWCC remains authoritative; we
             * merely stop holding an obsolete low-resolution operating point
             * after its own estimate and end-to-end telemetry say more fits.
             */
            val fastHeadroomRatio =
                if (nextRecoveryRung >= NATIVE_WARM_START_SHORT_EDGE) {
                    FAST_NATIVE_RECOVERY_BWE_HEADROOM_RATIO
                } else {
                    FAST_CLARITY_RECOVERY_BWE_HEADROOM_RATIO
                }
            /*
             * warmStartResizePending means the source is still native and no
             * spatial downgrade has actually happened. Recovery must never
             * "recover" that speculative lower control rung by committing a
             * real resize. Either pressure validates the downgrade or the
             * native-proof path above cancels it.
             *
             * 720 is a compatibility rung, not a permanent native-detail cap.
             * A continuous game may never reach the quiet-screen restore path.
             * Admit the profile's actual geometry only after measured RTP and
             * codec cost both project into that larger operating point. This
             * is a conservative probe, not a throughput guarantee: new pressure
             * still returns native detail to 720 before spending lower rungs.
             *
             * Missing bytes, codec identity, source supply, current dimensions
             * or fresh controller presentation cannot authorize this new rung.
             * Existing <=720 recovery and callers without a profile keep their
             * compatibility behavior.
             */
            val recoveryPixelScale =
                (nextRecoveryRung.toDouble() / currentRecoveryShortEdge)
                    .let { it * it }
            val measuredRecoveryHeadroom =
                profile != null &&
                    !implementation.isNullOrBlank() &&
                    !softwarePath &&
                    projectedRecoveryDemandBps?.let {
                        it <= profile.maxVideoBitrateBps
                    } == true &&
                    minOf(outbound.frameWidth, outbound.frameHeight) ==
                        currentRecoveryShortEdge &&
                    measuredSourceFps?.let {
                        it >= goal * FAST_CLARITY_RECOVERY_DELIVERY_RATIO
                    } == true &&
                    encodeMs?.let {
                        it * recoveryPixelScale < frameMs *
                            FAST_CLARITY_RECOVERY_CODEC_BUDGET_RATIO
                    } == true &&
                    decodeMs?.let {
                        it * recoveryPixelScale < frameMs *
                            FAST_CLARITY_RECOVERY_CODEC_BUDGET_RATIO
                    } == true &&
                    received != null &&
                    received.presentationSampleFresh &&
                    received.presentationSampleAgeMs?.let {
                        it in 0..received.intervalMs
                    } == true &&
                    received.presentationAgeMs?.let {
                        it in 0..received.intervalMs
                    } == true
            val nativeDetailHeadroom =
                !recoveringNativeDetail || measuredRecoveryHeadroom
            /*
             * A continuously held gesture must not permanently pin a recovered
             * stream below native detail. Admit a one-rung capacity probe only
             * with measured RTP demand, matching current source dimensions,
             * hardware identity, fresh glass and projected codec cost. Apply
             * the stricter codec margin to the NEXT geometry, not the current
             * cheap frames. No zero-cost/missing telemetry exception exists.
             *
             * This predicts capacity, not a hitch-free MediaCodec resize. Keep
             * the master/cadence veto, five-window proof, cooldown and pressure
             * rollback; never authorize a touch-down speculative resize.
             */
            val interactiveRecoveryHeadroom =
                measuredRecoveryHeadroom &&
                    nextRecoveryRung <= interactiveRecoveryCeiling &&
                    outbound.qualityLimitationReason.equals("none", ignoreCase = true) &&
                    encodeMs?.let {
                        it > 0.0 && it * recoveryPixelScale < frameMs *
                            INTERACTIVE_RECOVERY_CODEC_BUDGET_RATIO
                    } == true &&
                    decodeMs?.let {
                        it > 0.0 && it * recoveryPixelScale < frameMs *
                            INTERACTIVE_RECOVERY_CODEC_BUDGET_RATIO
                    } == true &&
                    queueMs?.let { it < INTERACTIVE_RECOVERY_MAX_QUEUE_MS } == true &&
                    jitterMs?.let { it < INTERACTIVE_RECOVERY_MAX_JITTER_MS } == true &&
                    bandwidthEstimateBps?.let {
                        it >= nextRecoveryBitrateBps *
                            INTERACTIVE_RECOVERY_BWE_HEADROOM_RATIO
                    } == true &&
                    received?.presentationSampleAgeMs?.let {
                        it in 0..INTERACTIVE_RECOVERY_MAX_GLASS_AGE_MS
                    } == true &&
                    received?.presentationAgeMs?.let {
                        it in 0..INTERACTIVE_RECOVERY_MAX_GLASS_AGE_MS
                    } == true
            val resolutionRecoveryAllowed =
                allowResolutionRecovery &&
                    (!interactionActive || interactiveRecoveryHeadroom) &&
                    !warmStartResizePending &&
                    nativeDetailHeadroom
            val fastRecoveryEvidence =
                healthy &&
                    resolutionRecoveryAllowed &&
                    bandwidthEstimateBps?.let {
                        it >= nextRecoveryBitrateBps * fastHeadroomRatio
                    } == true &&
                    outbound.roundTripTimeMs?.let {
                        it in 0..FAST_CLARITY_RECOVERY_MAX_RTT_MS
                    } == true &&
                    (outbound.packetLossRatio ?: 0.0) <
                        FAST_CLARITY_RECOVERY_MAX_LOSS_RATIO &&
                    queueMs?.let {
                        it < FAST_CLARITY_RECOVERY_MAX_QUEUE_MS
                    } == true &&
                    encodeMs?.let {
                        it < frameMs *
                            FAST_CLARITY_RECOVERY_CODEC_BUDGET_RATIO
                    } == true &&
                    received != null &&
                    decodeMs?.let {
                        it < frameMs *
                            FAST_CLARITY_RECOVERY_CODEC_BUDGET_RATIO
                    } == true &&
                    jitterMs?.let {
                        it < FAST_CLARITY_RECOVERY_MAX_JITTER_MS
                    } == true &&
                    received.presentedFps?.let {
                        it >= goal * FAST_CLARITY_RECOVERY_DELIVERY_RATIO
                    } == true &&
                    (received.maxRenderGapMs ?: Int.MAX_VALUE) <
                        FAST_CLARITY_RECOVERY_MAX_RENDER_GAP_MS &&
                    nowMs - lastBandwidthPressureAtMs >=
                        FAST_CLARITY_RECOVERY_PRESSURE_COOLDOWN_MS

            // A cadence trial must measure one variable at a time. Pressure
            // relief stays enabled, but do not also enlarge trial frames.
            healthySamples =
                if (healthy && resolutionRecoveryAllowed && !interactionActive) {
                    healthySamples + 1
                } else {
                    0
                }
            fastRecoverySamples =
                if (fastRecoveryEvidence) {
                    fastRecoverySamples + 1
                } else {
                    0
                }

            val sustainedRecoveryRequired =
                nextRecoveryRung >= NATIVE_WARM_START_SHORT_EDGE || interactionActive
            val fastSamplesRequired =
                if (sustainedRecoveryRequired) {
                    FAST_NATIVE_RECOVERY_SAMPLE_COUNT
                } else {
                    FAST_CLARITY_RECOVERY_SAMPLE_COUNT
                }
            val fastSettleMs =
                if (sustainedRecoveryRequired) {
                    FAST_NATIVE_RECOVERY_SETTLE_MS
                } else {
                    FAST_CLARITY_RECOVERY_SETTLE_MS
                }
            val fastRecoveryReady =
                fastRecoverySamples >= fastSamplesRequired &&
                    nowMs - changedAtMs >= fastSettleMs
            val conservativeRecoveryReady =
                healthySamples >= CONSERVATIVE_RECOVERY_SAMPLE_COUNT &&
                    nowMs - changedAtMs >= CONSERVATIVE_RECOVERY_SETTLE_MS

            if (
                nextRecoveryRung > currentRecoveryShortEdge &&
                (fastRecoveryReady ||
                    (!recoveringNativeDetail && conservativeRecoveryReady))
            ) {
                shortEdge = nextRecoveryRung
                interactiveRecoveryTarget = if (interactionActive) nextRecoveryRung else 0
                interactiveRecoveryAtMs = nowMs
                committedSourceShortEdge = shortEdge
                changedAtMs = nowMs
                healthySamples = 0
                fastRecoverySamples = 0
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
         * Keep source geometry stable until measured evidence explicitly commits
         * a spatial actuator move. The control-plane shortEdge may already be
         * lower for prediction/admission, but it is not producer geometry.
         */
        val edge = minOf(profile.captureWidthPx, profile.captureHeightPx)
        val sourceShortEdge =
            admittedSourceShortEdge(profile)
        if (edge <= sourceShortEdge) return profile
        val scale = sourceShortEdge.toDouble() / edge
        fun even(value: Int) = ((value * scale).roundToInt() / 2 * 2).coerceAtLeast(2)
        return profile.copy(
            captureWidthPx = even(profile.captureWidthPx),
            captureHeightPx = even(profile.captureHeightPx)
        )
    }

    private fun onSpatialPressureCommit(nextShortEdge: Int, nowMs: Long) {
        if (interactiveRecoveryTarget > nextShortEdge) {
            // A projected capacity model cannot predict every vendor resize
            // cost. Pressure during the existing settle period marks a failed
            // probe; do not repeat that target during the same interaction.
            // A later independent network dip must still be able to recover.
            if (nowMs - interactiveRecoveryAtMs in 0L..FAST_NATIVE_RECOVERY_SETTLE_MS) {
                interactiveRecoveryCeiling =
                    minOf(interactiveRecoveryCeiling, interactiveRecoveryTarget - 1)
            }
            interactiveRecoveryTarget = 0
        }
    }

    fun cadenceFloor(
        profile: CaptureProfile,
        motionActive: Boolean,
        nowMs: Long,
        interactionActive: Boolean = false
    ): Int {
        if (!motionActive) return 1

        /*
         * 360 is the terminal spatial rung. Keep ordinary active control at a
         * 30 fps UX floor, but let VideoCadenceGovernor bypass that floor under
         * measured severe CPU/network/presentation pressure. That preserves
         * readable pixels while still giving a failing link a temporal escape.
         */
        if (interactionActive) {
            return minOf(
                INTERACTION_CADENCE_FLOOR_FPS,
                profile.motionFps
            )
        }

        /*
         * Recent bandwidth pressure must not pin a readable 360 stream at a
         * low cadence after backlog drains. Passive motion holds 30 briefly;
         * severe cadence relief remains independently authoritative.
         */
        val bandwidthReliefActive =
            nowMs - lastBandwidthPressureAtMs in 0L..BANDWIDTH_PRESSURE_HOLD_MS
        if (bandwidthReliefActive) {
            return minOf(
                INTERACTION_CADENCE_FLOOR_FPS,
                profile.motionFps
            )
        }

        // After a real resize, keep one short drain window at the readable
        // interaction cadence. Once settled, the cadence owner is unconstrained.
        return if (nowMs - changedAtMs < SETTLE_MS) {
            minOf(
                INTERACTION_CADENCE_FLOOR_FPS,
                profile.motionFps
            )
        } else {
            1
        }
    }

    fun bitrateCeiling(
        profile: CaptureProfile,
        motionActive: Boolean,
        targetFps: Int = BASELINE_MOTION_FPS
    ): Int {
        if (!motionActive && !holdingResolution) return profile.maxVideoBitrateBps

        /*
         * maxBitrateBps is only a ceiling; GCC/TWCC still decides the actual
         * send rate. The important invariant is that this ceiling describes the
         * geometry we have ACTUALLY admitted to VideoSource/MediaCodec.
         *
         * shortEdge may be a speculative 360 control-plane prediction while
         * committedSourceShortEdge is still native 720/1080. Applying the
         * speculative bitrate ceiling at that moment creates a contradictory
         * operating point: more motion FPS at full pixels, but a sharply lower
         * encoder ceiling. Vendor rate control can answer that step with a
         * large QP/key-frame transient or temporary under-delivery, which looks
         * exactly like first-motion judder.
         *
         * Once measured pressure commits a spatial rung, source geometry and
         * bitrate ceiling move together. Congested links remain protected
         * before that point because WebRTC congestion control is authoritative;
         * a higher max ceiling never forces the sender to transmit above BWE.
         */
        val admittedShortEdge =
            admittedSourceShortEdge(profile)
        val motionCeiling =
            if (admittedShortEdge <= 540) {
                nominalMotionBitrateBps(admittedShortEdge, targetFps)
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

    /**
     * Source geometry that the app has actually admitted to VideoSource /
     * MediaCodec. shortEdge is intentionally excluded while a warm-start
     * prediction is still uncommitted.
     *
     * With a CaptureProfile, Int.MAX_VALUE means there is no app clamp and the
     * profile geometry is physically active. Without a profile, retain the
     * historical fallback to the committed rung or, if none exists, shortEdge.
     */
    private fun admittedSourceShortEdge(
        profile: CaptureProfile? = null
    ): Int {
        val committed =
            committedSourceShortEdge
                .takeUnless { it == Int.MAX_VALUE }

        return profile?.let {
            val profileShortEdge =
                minOf(it.captureWidthPx, it.captureHeightPx)
            committed?.let { edge ->
                minOf(profileShortEdge, edge)
            } ?: profileShortEdge
        } ?: committed ?: shortEdge
    }

    /**
     * Actual encoder/RTP demand relative to GCC/TWCC path capacity.
     *
     * A fixed resolution table cannot describe screen entropy: 720p text and
     * 720p gameplay can differ by several Mbps. Interval byte deltas therefore
     * own predictive decisions whenever they are available.
     */
    private fun bandwidthUtilization(
        sender: VideoHealthWindow,
        bandwidthEstimateBps: Double
    ): Double? {
        if (
            !bandwidthEstimateBps.isFinite() ||
            bandwidthEstimateBps <= 0.0
        ) {
            return null
        }

        val sentBitrateBps =
            sender.bitrateBps
                .toDouble()
                .takeIf { it.isFinite() && it > 0.0 }
                ?: return null

        return (sentBitrateBps / bandwidthEstimateBps)
            .takeIf { it.isFinite() && it >= 0.0 }
    }

    /**
     * Estimate one spatial recovery step from the content that is actually on
     * screen. Normalize the measured RTP rate to the requested cadence, scale
     * by pixel area, and add a codec/content-change safety margin. The existing
     * multi-window end-to-end recovery gates and GCC/TWCC remain authoritative.
     *
     * Low readable rungs still use the conservative nominal table for
     * maxBitrateBps. This only prevents a cheap
     * form/text screen from staying blurry because a fixed "720p needs X Mbps"
     * assumption is larger than its real encoded demand.
     */
    private fun projectedRecoveryBitrateBps(
        sender: VideoHealthWindow,
        currentShortEdge: Int,
        nextShortEdge: Int,
        targetFps: Int,
        maxBitrateBps: Int
    ): Double? {
        if (
            currentShortEdge <= 0 ||
            nextShortEdge <= currentShortEdge ||
            maxBitrateBps <= 0
        ) {
            return null
        }

        val sentBitrateBps =
            sender.bitrateBps
                .toDouble()
                .takeIf { it.isFinite() && it > 0.0 }
                ?: return null
        val measuredFps =
            sender.fps
                .takeIf {
                    it.isFinite() &&
                        it >= MIN_MOVING_SOURCE_FPS
                }
                ?: return null
        val cadenceScale =
            targetFps
                .coerceIn(MIN_PREDICTIVE_FPS, MAX_MOTION_TARGET_FPS)
                .toDouble() /
                measuredFps
        val spatialScale =
            nextShortEdge.toDouble() /
                currentShortEdge.toDouble()
        val projected =
            sentBitrateBps *
                cadenceScale *
                spatialScale *
                spatialScale *
                RECOVERY_CONTENT_PROJECTION_MARGIN

        return projected
            .coerceAtMost(maxBitrateBps.toDouble())
            .takeIf { it.isFinite() && it > 0.0 }
    }

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
                edge <= CLARITY_FLOOR_SHORT_EDGE -> 900_000.0
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
        const val HD_PLUS_SHORT_EDGE = 900
        const val INTERACTIVE_RECOVERY_CODEC_BUDGET_RATIO = 0.35
        const val INTERACTIVE_RECOVERY_MAX_QUEUE_MS = 10.0
        const val INTERACTIVE_RECOVERY_MAX_JITTER_MS = 18.0
        const val INTERACTIVE_RECOVERY_BWE_HEADROOM_RATIO = 1.60
        const val INTERACTIVE_RECOVERY_MAX_GLASS_AGE_MS = 1_000
        const val MAX_WARM_START_QUIET_FRAMES = 3
        const val WARM_START_MAX_ENCODE_MS = 8.0
        const val WARM_START_MAX_QUEUE_MS = 15.0
        const val WARM_START_MAX_RTT_MS = 250
        const val WARM_START_MAX_LOSS_RATIO = 0.02
        const val WARM_START_BWE_HEADROOM_RATIO = 1.25
        val SOFTWARE_ENCODER_MARKERS =
            arrayOf(
                "libvpx", "libaom", "openh264", "software",
                "omx.google.", "c2.android.", "c2.google.", "sw.", "ffmpeg"
            )
        const val SETTLE_MS = 3_000L
        // Follow the same 6-second validity ceiling as VideoHealthWindowTracker.
        const val MAX_SENDER_SAMPLE_GAP_MS = 6_000L
        const val BANDWIDTH_FAST_SETTLE_MS = 1_000L
        const val BWE_PREDICTIVE_SETTLE_MS = 1_000L
        const val BWE_PRESSURE_HEADROOM_RATIO = 1.10
        /*
         * Predictive BWE relief is driven by measured RTP utilization whenever
         * stats are available. Use the same capacity reserve as the clarity
         * guard so clean delivery cannot be accepted by cadence policy and
         * simultaneously blurred by the pixel policy. Reactive
         * queue/loss/decode alarms remain independent and can act sooner.
         */
        const val BWE_PREDICTIVE_PRESSURE_UTILIZATION_RATIO =
            1.0 / BWE_PRESSURE_HEADROOM_RATIO

        /*
         * Clarity guard: if high cadence is the only thing that no longer fits,
         * keep the current pixels and hand a lower temporal ceiling to the
         * cadence owner. Two stable BWE windows are required by
         * VideoCadenceGovernor before it acts.
         */
        const val CLARITY_PRESERVING_FPS_FLOOR = 30
        const val CLARITY_PRESERVING_BWE_HEADROOM_RATIO =
            BWE_PRESSURE_HEADROOM_RATIO
        const val CLARITY_PRESERVING_CODEC_BUDGET_RATIO = 0.80
        const val CLARITY_PRESERVING_MAX_QUEUE_MS = 35.0
        const val CLARITY_PRESERVING_MAX_RTT_MS = 450
        const val CLARITY_PRESERVING_MAX_LOSS_RATIO = 0.04
        const val CLARITY_PRESERVING_MAX_JITTER_MS = 60.0
        const val CLARITY_PRESERVING_MAX_RENDER_GAP_MS = 100
        const val BWE_RECOVERY_HEADROOM_RATIO = 1.20
        const val RECOVERY_CONTENT_PROJECTION_MARGIN = 1.15

        /*
         * A clean completed moving window may cancel an uncommitted warm-start
         * prediction without resizing the already-native source.
         */
        const val WARM_START_VALIDATION_DELIVERY_RATIO = 0.90
        const val WARM_START_VALIDATION_CODEC_BUDGET_RATIO = 0.50
        const val WARM_START_VALIDATION_MAX_QUEUE_MS = 20.0
        const val WARM_START_VALIDATION_MAX_RTT_MS = 300
        const val WARM_START_VALIDATION_MAX_LOSS_RATIO = 0.025
        const val WARM_START_VALIDATION_MAX_UTILIZATION_RATIO = 0.75

        /*
         * Fast clarity recovery is a measured capacity probe, not a forced
         * bitrate floor. 360/540 may return after three consecutive clean
         * end-to-end windows with >=30% BWE headroom. Detail >=720 requires five
         * windows and >=45% headroom. Unknown/incomplete telemetry falls back
         * to conservative twelve-window recovery only for the <=720 rungs.
         */
        const val FAST_CLARITY_RECOVERY_BWE_HEADROOM_RATIO = 1.30
        const val FAST_NATIVE_RECOVERY_BWE_HEADROOM_RATIO = 1.45
        const val FAST_CLARITY_RECOVERY_SAMPLE_COUNT = 3
        const val FAST_NATIVE_RECOVERY_SAMPLE_COUNT = 5
        const val FAST_CLARITY_RECOVERY_SETTLE_MS = 3_000L
        const val FAST_NATIVE_RECOVERY_SETTLE_MS = 5_000L
        const val FAST_CLARITY_RECOVERY_PRESSURE_COOLDOWN_MS = 2_500L
        const val FAST_CLARITY_RECOVERY_MAX_RTT_MS = 250
        const val FAST_CLARITY_RECOVERY_MAX_LOSS_RATIO = 0.02
        const val FAST_CLARITY_RECOVERY_MAX_QUEUE_MS = 15.0
        const val FAST_CLARITY_RECOVERY_CODEC_BUDGET_RATIO = 0.45
        const val FAST_CLARITY_RECOVERY_MAX_JITTER_MS = 30.0
        const val FAST_CLARITY_RECOVERY_DELIVERY_RATIO = 0.90
        const val FAST_CLARITY_RECOVERY_MAX_RENDER_GAP_MS = 80
        const val CONSERVATIVE_RECOVERY_SAMPLE_COUNT = 12
        const val CONSERVATIVE_RECOVERY_SETTLE_MS = 12_000L

        /*
         * Match PhotonFreshnessGovernor's material-repair thresholds. A huge
         * frame is only actionable when transport feedback independently proves
         * that recovery work was active in the same completed stats window.
         */
        const val RTP_BURST_RETRANSMIT_RATIO = 0.08
        const val RTP_BURST_NACK_RATE_PER_SECOND = 2.0
        const val RTP_BURST_FAST_SETTLE_MS = 1_000L
        const val RTP_BURST_POST_SPATIAL_GUARD_MS = 3_000L

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

        // Raw MediaProjection starvation is a different failure mode from
        // encoder/network under-delivery. These thresholds intentionally line
        // up with the passive-motion hold region: stable 24/30/60 fps content
        // never qualifies, while the observed 2-6 fps collapse and >140 ms
        // producer gaps do.
        const val MIN_PRODUCER_STARVATION_FPS = 2.5
        /*
         * Cold interaction bootstrap is allowed slightly below the passive
         * motion hold threshold because the independent post-input probe has
         * already proven that fresh pixels were expected. Keep this above the
         * common 0-1 fps static/blink region.
         */
        const val MIN_CAUSAL_INTERACTION_SOURCE_FPS = 1.5
        const val SEVERE_PRODUCER_STARVATION_FPS = 6.0
        const val MIN_PRODUCER_STALL_GAP_MS = 140.0
        const val SEVERE_PRODUCER_STALL_GAP_MS = 250.0
        const val PRODUCER_STALL_FRAME_MULTIPLIER = 4.0
        const val PRODUCER_STARVATION_FAST_SETTLE_MS = 1_000L

        const val INTERACTION_DELIVERY_RATIO = 0.75
        const val PASSIVE_DELIVERY_RATIO = 0.75
        const val NETWORK_QUEUE_PRESSURE_MS = 90.0
        const val PROVEN_NETWORK_LOSS_RATIO = 0.06
        const val PROVEN_NETWORK_RTT_MS = 650
        const val SEVERE_NETWORK_QUEUE_MS = 250.0
        const val CLARITY_FLOOR_SHORT_EDGE = 360
        const val DETAIL_CLARITY_FLOOR_SHORT_EDGE = 540
        const val INTERACTION_CADENCE_FLOOR_FPS = 30
        const val IDLE_RESTORE_MS = 8_000L
    }
}
