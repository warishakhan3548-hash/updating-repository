package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import java.io.File
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic policy-in-the-loop "digital twin" for gaming smoothness.
 *
 * This is deliberately NOT claimed to be a physical-device/WebRTC benchmark.
 * It drives the production MotionVideoBudget, PhotonFreshnessGovernor and
 * VideoCadenceGovernor with reproducible transport/codec/glass evidence.
 *
 * The lab exists to catch control-loop regressions automatically:
 * - sticky 15/20 fps after a transient loss burst,
 * - runaway queue residence,
 * - over-aggressive cadence collapse,
 * - failure to climb on a clean 60 Hz path,
 * - poor presented-frame ratio after network recovery.
 *
 * Every run writes a CSV trace consumed by tools/render_gaming_smoothness_lab.py
 * to produce synthetic "what the user would feel" motion videos in CI.
 */
class GamingSmoothnessLabTest {
    private data class Net(
        val bandwidthKbps: Double,
        val rttMs: Int,
        val loss: Double,
        val baseJitterMs: Double
    )

    private data class Scenario(
        val name: String,
        val durationMs: Long,
        val sourceFps: Double,
        val netAt: (Long) -> Net,
        val minFinalCap: Int,
        val minRecoveredCap: Int,
        val recoveryDeadlineMs: Long?,
        val milestoneCap: Int? = null,
        val milestoneDeadlineMs: Long? = null,
        val maxPostRecoveryLagWindows: Int,
        val minTailPresentFps: Double
    )

    private data class Row(
        val scenario: String,
        val timeMs: Long,
        val bandwidthKbps: Double,
        val rttMs: Int,
        val loss: Double,
        val sourceFps: Double,
        val targetFps: Int,
        val sendFps: Double,
        val decodeFps: Double,
        val presentFps: Double,
        val shortEdge: Int,
        val queueMs: Double,
        val jitterMs: Double,
        val encodeMs: Double,
        val decodeMs: Double,
        val maxGapMs: Int,
        val photonPostAckMs: Int,
        val glassRatio: Double,
        val lag: Boolean,
        val decision: String
    )

    private val profile =
        CaptureProfile(
            displayWidthPx = 1080,
            displayHeightPx = 2400,
            captureWidthPx = 1080,
            captureHeightPx = 2400,
            fps = 45,
            maxVideoBitrateBps = 10_000_000,
            tier = CaptureTier.STANDARD,
            motionFps = 60
        )

    @Test
    fun gamingNetworkMatrixStaysFreshAndRecovers() {
        val scenarios =
            listOf(
                Scenario(
                    name = "clean_wifi_60hz",
                    durationMs = 40_000,
                    sourceFps = 60.0,
                    netAt = {
                        Net(
                            bandwidthKbps = 9_000.0,
                            rttMs = 24,
                            loss = 0.002,
                            baseJitterMs = 5.0
                        )
                    },
                    minFinalCap = 55,
                    minRecoveredCap = 55,
                    recoveryDeadlineMs = null,
                    milestoneCap = 60,
                    milestoneDeadlineMs = 16_000,
                    maxPostRecoveryLagWindows = 1,
                    minTailPresentFps = 50.0
                ),
                Scenario(
                    name = "stable_4g",
                    durationMs = 40_000,
                    sourceFps = 60.0,
                    netAt = {
                        Net(
                            bandwidthKbps = 4_000.0,
                            rttMs = 78,
                            loss = 0.012,
                            baseJitterMs = 10.0
                        )
                    },
                    minFinalCap = 45,
                    minRecoveredCap = 45,
                    recoveryDeadlineMs = null,
                    milestoneCap = 50,
                    milestoneDeadlineMs = 14_000,
                    maxPostRecoveryLagWindows = 2,
                    minTailPresentFps = 40.0
                ),
                Scenario(
                    name = "burst_loss_then_recover",
                    durationMs = 42_000,
                    sourceFps = 60.0,
                    netAt = { t ->
                        when (t) {
                            in 8_000L until 12_000L ->
                                Net(
                                    bandwidthKbps = 650.0,
                                    rttMs = 220,
                                    loss = 0.16,
                                    baseJitterMs = 45.0
                                )
                            in 12_000L until 16_000L ->
                                Net(
                                    bandwidthKbps = 2_200.0,
                                    rttMs = 105,
                                    loss = 0.035,
                                    baseJitterMs = 16.0
                                )
                            else ->
                                Net(
                                    bandwidthKbps = 5_500.0,
                                    rttMs = 55,
                                    loss = 0.008,
                                    baseJitterMs = 8.0
                                )
                        }
                    },
                    minFinalCap = 45,
                    minRecoveredCap = 30,
                    recoveryDeadlineMs = 19_000,
                    maxPostRecoveryLagWindows = 3,
                    minTailPresentFps = 40.0
                ),
                Scenario(
                    name = "lossy_mobile_6pct",
                    durationMs = 32_000,
                    sourceFps = 45.0,
                    netAt = {
                        Net(
                            bandwidthKbps = 1_800.0,
                            rttMs = 145,
                            loss = 0.06,
                            baseJitterMs = 22.0
                        )
                    },
                    minFinalCap = 24,
                    minRecoveredCap = 24,
                    recoveryDeadlineMs = null,
                    maxPostRecoveryLagWindows = 10,
                    minTailPresentFps = 18.0
                )
            )

        val allRows = mutableListOf<Row>()
        val failures = mutableListOf<String>()

        for (scenario in scenarios) {
            val rows = runScenario(scenario)
            allRows += rows

            val tail = rows.takeLast(10)
            val final = rows.last()
            val tailPresent = tail.map { it.presentFps }.average()
            val lagAfter16s =
                rows.count {
                    it.timeMs >= 16_000L && it.lag
                }

            if (final.targetFps < scenario.minFinalCap) {
                failures +=
                    "${scenario.name}: final cap ${final.targetFps} < ${scenario.minFinalCap}"
            }
            if (tailPresent < scenario.minTailPresentFps) {
                failures +=
                    "${scenario.name}: tail present %.1ffps < %.1ffps"
                        .format(tailPresent, scenario.minTailPresentFps)
            }
            if (lagAfter16s > scenario.maxPostRecoveryLagWindows) {
                failures +=
                    "${scenario.name}: $lagAfter16s post-recovery lag windows > " +
                        scenario.maxPostRecoveryLagWindows
            }

            scenario.recoveryDeadlineMs?.let { deadline ->
                val recoveredAt =
                    rows.firstOrNull {
                        it.timeMs >= 12_000L &&
                            it.targetFps >= scenario.minRecoveredCap &&
                            !it.lag
                    }?.timeMs
                if (recoveredAt == null || recoveredAt > deadline) {
                    failures +=
                        "${scenario.name}: recovery to ${scenario.minRecoveredCap}fps " +
                            "missed deadline ${deadline}ms (actual=$recoveredAt)"
                }
            }

            if (
                scenario.milestoneCap != null &&
                scenario.milestoneDeadlineMs != null
            ) {
                val reachedAt =
                    rows.firstOrNull {
                        it.targetFps >= scenario.milestoneCap &&
                            !it.lag
                    }?.timeMs
                if (
                    reachedAt == null ||
                    reachedAt > scenario.milestoneDeadlineMs
                ) {
                    failures +=
                        "${scenario.name}: ${scenario.milestoneCap}fps clean-ramp " +
                            "missed ${scenario.milestoneDeadlineMs}ms deadline " +
                            "(actual=$reachedAt)"
                }
            }
        }

        writeReports(allRows, failures)

        assertTrue(
            buildString {
                appendLine("Gaming Smoothness Lab failed:")
                failures.forEach { appendLine(" - $it") }
            },
            failures.isEmpty()
        )
    }

    private fun runScenario(scenario: Scenario): List<Row> {
        val cadence =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 30
            )
        val budget = MotionVideoBudget()
        val photon = PhotonFreshnessGovernor()
        budget.primeForMotion(
            profile = profile,
            nowMs = 0L,
            targetFps = 30
        )

        var queueMs = 0.0
        var presentationSequence = 1L
        val rows = mutableListOf<Row>()

        var nowMs = 500L
        while (nowMs <= scenario.durationMs) {
            val net = scenario.netAt(nowMs)
            val target = cadence.cap.coerceIn(15, 60)
            val edge = budget.shortEdge
            /*
             * Keep the digital-twin plant independent from the configured RTP
             * max-bitrate ceiling. In production maxBitrateBps is an admission
             * ceiling, not an instruction to send that many bits; libwebrtc
             * GCC/TWCC chooses the actual rate below it. Treating the ceiling as
             * demand makes a healthy 9 Mbps path look overloaded merely because
             * the full-quality ceiling is 10 Mbps.
             *
             * The plant instead generates an independent moving-screen workload
             * from the control-plane pixel/cadence operating point. This keeps
             * the lab useful for queue/cadence regressions without encoding the
             * exact implementation under test back into the simulated network.
             */
            val demandKbps =
                max(
                    260.0,
                    labMotionDemandKbps(
                        edge = edge,
                        targetFps = target
                    )
                )
            val overloadRatio =
                ((demandKbps - net.bandwidthKbps) / demandKbps)
                    .coerceAtLeast(0.0)
            val drainRatio =
                ((net.bandwidthKbps - demandKbps) / demandKbps)
                    .coerceAtLeast(0.0)
            queueMs =
                (
                    queueMs +
                        overloadRatio * 115.0 -
                        drainRatio * 85.0 -
                        if (overloadRatio == 0.0) 12.0 else 0.0
                    )
                    .coerceIn(0.0, 600.0)

            val pixelLoad =
                (edge / 720.0) * (edge / 720.0)
            val encodeMs =
                (
                    3.8 +
                        8.0 * pixelLoad * (target / 60.0)
                    )
                    .coerceAtLeast(3.0)
            val bandwidthDelivery =
                (net.bandwidthKbps / demandKbps)
                    .coerceIn(0.18, 1.0)
            val queuePenalty =
                (1.0 - queueMs / 780.0)
                    .coerceIn(0.34, 1.0)
            val lossPenalty =
                (1.0 - net.loss * 1.45)
                    .coerceIn(0.45, 1.0)

            val sendFps =
                min(scenario.sourceFps, target.toDouble()) *
                    bandwidthDelivery *
                    queuePenalty *
                    lossPenalty
            val decodeMs =
                2.8 + 3.2 * pixelLoad
            val decodeFps =
                sendFps *
                    (1.0 - net.loss * 0.35)
                        .coerceIn(0.70, 1.0)
            val jitterMs =
                (
                    net.baseJitterMs +
                        net.rttMs * 0.035 +
                        net.loss * 240.0 +
                        queueMs * 0.12
                    )
                    .coerceAtLeast(2.0)
            val renderPenalty =
                when {
                    jitterMs >= 140.0 -> 0.72
                    jitterMs >= 90.0 -> 0.84
                    jitterMs >= 55.0 -> 0.92
                    else -> 0.985
                }
            val presentFps =
                decodeFps * renderPenalty
            val expectedGlass =
                min(target.toDouble(), min(sendFps, decodeFps))
                    .coerceAtLeast(1.0)
            val glassRatio =
                (presentFps / expectedGlass)
                    .coerceIn(0.0, 1.0)
            val baseGap =
                ceil(1_000.0 / max(presentFps, 1.0))
                    .toInt()
            val burstGap =
                when {
                    net.loss >= 0.12 -> 95
                    net.loss >= 0.05 -> 42
                    net.loss >= 0.025 -> 22
                    else -> 0
                }
            val maxGapMs =
                (baseGap + burstGap + (queueMs * 0.18).roundToInt())
                    .coerceAtLeast(baseGap)
            val postAckMs =
                (
                    baseGap +
                        jitterMs * 0.55 +
                        queueMs * 0.08
                    )
                    .roundToInt()
                    .coerceIn(5, 5_000)
            val sampleFrames =
                (sendFps * 0.5)
                    .roundToInt()
                    .coerceAtLeast(0)
            val receiverFrames =
                (decodeFps * 0.5)
                    .roundToInt()
                    .coerceAtLeast(0)
            val presentedFrames =
                (presentFps * 0.5)
                    .roundToInt()
                    .coerceAtLeast(0)

            val limited =
                if (
                    net.bandwidthKbps <
                    demandKbps * 0.90
                ) {
                    "bandwidth"
                } else {
                    "none"
                }

            val outbound =
                VideoHealthSnapshot(
                    direction = "outbound",
                    codec = "video/H264",
                    bytes = 0,
                    frames = sampleFrames.toLong(),
                    framesSecondary = sampleFrames.toLong(),
                    packets = max(1, sampleFrames * 3).toLong(),
                    packetsLost = 0,
                    frameWidth = edge,
                    frameHeight = edge * 2,
                    qualityLimitationReason = limited,
                    roundTripTimeMs = net.rttMs,
                    packetLossRatio = net.loss,
                    codecImplementation = "c2.lab.avc.encoder",
                    availableOutgoingBitrateBps =
                        net.bandwidthKbps * 1_000.0,
                    recent =
                        VideoHealthWindow(
                            intervalMs = 500,
                            frames = sampleFrames,
                            processingMs = encodeMs,
                            jitterMs = null,
                            dropped = null,
                            freezes = null,
                            bitrateBps =
                                (
                                    min(
                                        demandKbps,
                                        net.bandwidthKbps
                                    ) * 1_000.0
                                    ).toLong(),
                            sendQueueMs = queueMs
                        )
                )

            val receiver =
                VideoHealthWindow(
                    intervalMs = 500,
                    frames = receiverFrames,
                    processingMs = decodeMs,
                    jitterMs = jitterMs,
                    dropped =
                        max(
                            0,
                            sampleFrames - receiverFrames
                        ),
                    freezes =
                        if (presentFps < 5.0) 1 else 0,
                    presentationIntervalMs = 500,
                    presentedFrames = presentedFrames,
                    maxRenderGapMs = maxGapMs,
                    presentationAgeMs = min(1_500, maxGapMs),
                    displayRefreshRateHz = 60.0,
                    jitterTargetMs = jitterMs * 1.12,
                    presentationSampleSequence =
                        presentationSequence++,
                    presentationSampleAgeMs = 40,
                    presentationSampleFresh = true,
                    inputToGlassUpperBoundMs =
                        net.rttMs + postAckMs,
                    commandAckMs = net.rttMs,
                    postAckPresentMs = postAckMs,
                    photonSampleSequence =
                        presentationSequence,
                    photonSampleAgeMs = 40,
                    photonSampleFresh = true
                )

            val photonPolicy =
                photon.observe(
                    outbound = outbound,
                    receiver = receiver,
                    targetFps = target,
                    interactionActive = true,
                    nowMs = nowMs
                )

            val resolutionChanged =
                budget.observe(
                    outbound = outbound,
                    receiver = receiver,
                    sourceFps = scenario.sourceFps,
                    motionActive = true,
                    targetFps = target,
                    nowMs = nowMs,
                    interactionActive = true,
                    allowResolutionRecovery = false
                )

            cadence.observe(
                outbound = outbound,
                receiver = receiver,
                requestedFps = cadence.cap,
                nowMs = nowMs,
                minimumFps =
                    budget.cadenceFloor(
                        profile = profile,
                        motionActive = true,
                        nowMs = nowMs,
                        interactionActive = true
                    ),
                producerFps = scenario.sourceFps,
                maximumFps = 60,
                allowHighCadenceProbe =
                    !resolutionChanged &&
                        photonPolicy.allowCadencePromotion
            )
            cadence.tryProbeDuringInteraction(
                outbound = outbound,
                receiver = receiver,
                producerFps = scenario.sourceFps,
                interactionActive = true,
                nowMs = nowMs
            )

            val lag =
                glassRatio < 0.80 ||
                    maxGapMs >= 110 ||
                    queueMs >= 140.0

            rows +=
                Row(
                    scenario = scenario.name,
                    timeMs = nowMs,
                    bandwidthKbps = net.bandwidthKbps,
                    rttMs = net.rttMs,
                    loss = net.loss,
                    sourceFps = scenario.sourceFps,
                    targetFps = cadence.cap,
                    sendFps = sendFps,
                    decodeFps = decodeFps,
                    presentFps = presentFps,
                    shortEdge = budget.shortEdge,
                    queueMs = queueMs,
                    jitterMs = jitterMs,
                    encodeMs = encodeMs,
                    decodeMs = decodeMs,
                    maxGapMs = maxGapMs,
                    photonPostAckMs = postAckMs,
                    glassRatio = glassRatio,
                    lag = lag,
                    decision = cadence.debugSummary(nowMs)
                )
            nowMs += 500L
        }

        return rows
    }

    private fun labMotionDemandKbps(
        edge: Int,
        targetFps: Int
    ): Double {
        val baselineKbps =
            when {
                edge <= 180 -> 350.0
                edge <= 240 -> 500.0
                edge <= 360 -> 900.0
                edge <= 540 -> 1_800.0
                else -> 3_200.0
            }
        val cadenceScale =
            targetFps
                .coerceIn(15, 60)
                .toDouble() / 30.0
        /*
         * Screen motion is bursty rather than constant-CBR. Preserve the
         * historical plant's cadence-dependent utilization envelope while
         * keeping the model independent from MotionVideoBudget.bitrateCeiling().
         */
        val utilization =
            0.72 + 0.28 * targetFps.coerceIn(15, 60) / 60.0
        return baselineKbps * cadenceScale * utilization
    }

    private fun writeReports(
        rows: List<Row>,
        failures: List<String>
    ) {
        val root =
            File(
                "build/reports/gaming-smoothness-lab"
            )
        root.mkdirs()

        File(root, "trace.csv").printWriter().use { out ->
            out.println(
                "scenario,time_ms,bandwidth_kbps,rtt_ms,loss,source_fps," +
                    "target_fps,send_fps,decode_fps,present_fps,short_edge," +
                    "queue_ms,jitter_ms,encode_ms,decode_ms,max_gap_ms," +
                    "post_ack_ms,glass_ratio,lag,decision"
            )
            rows.forEach { r ->
                out.println(
                    listOf(
                        r.scenario,
                        r.timeMs,
                        "%.1f".format(r.bandwidthKbps),
                        r.rttMs,
                        "%.4f".format(r.loss),
                        "%.1f".format(r.sourceFps),
                        r.targetFps,
                        "%.2f".format(r.sendFps),
                        "%.2f".format(r.decodeFps),
                        "%.2f".format(r.presentFps),
                        r.shortEdge,
                        "%.1f".format(r.queueMs),
                        "%.1f".format(r.jitterMs),
                        "%.1f".format(r.encodeMs),
                        "%.1f".format(r.decodeMs),
                        r.maxGapMs,
                        r.photonPostAckMs,
                        "%.3f".format(r.glassRatio),
                        r.lag,
                        r.decision.replace(',', ';')
                    ).joinToString(",")
                )
            }
        }

        val byScenario = rows.groupBy { it.scenario }
        File(root, "summary.txt").printWriter().use { out ->
            out.println("Aaris Gaming Smoothness Lab")
            out.println("==========================")
            byScenario.forEach { (name, samples) ->
                val tail = samples.takeLast(10)
                out.println()
                out.println(name)
                out.println(
                    " finalTarget=${samples.last().targetFps}fps" +
                        " finalEdge=${samples.last().shortEdge}" +
                        " tailPresent=%.1ffps".format(
                            tail.map { it.presentFps }.average()
                        ) +
                        " maxQueue=%.0fms".format(
                            samples.maxOf { it.queueMs }
                        ) +
                        " maxGap=${samples.maxOf { it.maxGapMs }}ms" +
                        " lagWindows=${samples.count { it.lag }}"
                )
            }
            out.println()
            if (failures.isEmpty()) {
                out.println("RESULT: PASS")
            } else {
                out.println("RESULT: FAIL")
                failures.forEach { out.println(" - $it") }
            }
        }
    }
}
