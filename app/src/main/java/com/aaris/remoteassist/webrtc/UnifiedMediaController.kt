package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * One app-level authority for resolution, capture FPS and bitrate ceiling.
 * WebRTC/GCC still owns congestion control, pacing and the actual send rate.
 *
 * Measurements can be frequent; quality decisions are intentionally slow.
 * A quiet second or one bad sample never changes the operating point.
 */
internal class UnifiedMediaController(
    initialProfile: CaptureProfile,
    private val maxFps: Int = 60
) {
    internal enum class PressureKind { NONE, NETWORK, DEVICE, RECEIVER, MIXED }

    internal data class OperatingPoint(
        val level: Int,
        val shortEdge: Int,
        val fps: Int,
        val bitrateCeilingBps: Int
    )

    private var level =
        when (initialProfile.tier) {
            CaptureTier.HIGH, CaptureTier.STANDARD -> 1
            CaptureTier.BALANCED -> 3
            CaptureTier.LOW -> 4
        }

    private var badWindows = 0
    private var goodWindows = 0
    private var lastChangeAtMs = Long.MIN_VALUE / 2
    private var recoveryBlockedUntilMs = Long.MIN_VALUE / 2
    private var lastObservedAtMs = Long.MIN_VALUE / 2
    private var filteredBweBps: Double? = null
    private var lastPressure = PressureKind.NONE
    private var lastDecision = "startup"

    fun observe(
        profile: CaptureProfile,
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        sourceFps: Double?,
        interactionActive: Boolean,
        deviceFpsLimit: Int,
        displayRefreshRateHz: Double?,
        nowMs: Long
    ): Boolean {
        val sender = outbound.recent ?: return false
        if (sender.intervalMs !in 400..6000) return false

        if (nowMs - lastObservedAtMs !in 0L..6000L) {
            badWindows = 0
            goodWindows = 0
        }
        lastObservedAtMs = nowMs

        outbound.availableOutgoingBitrateBps
            ?.takeIf { it.isFinite() && it > 0.0 }
            ?.let { sample ->
                filteredBweBps =
                    filteredBweBps?.let { old ->
                        old * 0.80 + sample * 0.20
                    } ?: sample
            }

        val point = operatingPoint(profile, deviceFpsLimit, displayRefreshRateHz)
        val frameMs = 1000.0 / point.fps.coerceAtLeast(1).toDouble()
        val validSource =
            sourceFps?.takeIf { it.isFinite() && it >= 0.0 }
        val producerMoving =
            validSource?.let { it >= 8.0 } == true
        val activeMedia =
            interactionActive || producerMoving || sender.fps >= 8.0

        // Silence is not a bandwidth test and never earns a promotion.
        if (!activeMedia) {
            badWindows = 0
            goodWindows = 0
            lastPressure = PressureKind.NONE
            return false
        }

        val expectedSender =
            validSource
                ?.takeIf { it >= 8.0 }
                ?.let { minOf(point.fps.toDouble(), it) }
        val senderRatio =
            expectedSender
                ?.takeIf { it > 0.0 }
                ?.let { (sender.fps / it).coerceIn(0.0, 2.0) }

        val received =
            receiver?.takeIf {
                it.intervalMs in 400..6000 && it.frames >= 2
            }
        val expectedReceiver =
            received?.let {
                minOf(point.fps.toDouble(), sender.fps)
                    .takeIf { value -> value >= 8.0 }
            }
        val receiverRatio =
            if (received != null && expectedReceiver != null) {
                (received.fps / expectedReceiver).coerceIn(0.0, 2.0)
            } else null

        val expectedGlass =
            if (received != null) {
                minOf(point.fps.toDouble(), sender.fps, received.fps)
                    .takeIf { it >= 8.0 }
            } else null
        val glassRatio =
            if (expectedGlass != null) {
                received.presentedFps
                    ?.let { (it / expectedGlass).coerceIn(0.0, 2.0) }
            } else null

        fun valid(value: Double?): Double? =
            value?.takeIf { it.isFinite() && it >= 0.0 }

        val encodeMs = valid(sender.processingMs)
        val decodeMs = valid(received?.processingMs)
        val sendResidenceMs = valid(sender.sendQueueMs)
        val playoutMs = valid(received?.playoutDelayMs)
        val renderGapMs =
            received?.maxRenderGapMs
                ?.takeIf { it >= 0 }
                ?.toDouble()
        val loss =
            valid(outbound.packetLossRatio) ?: 0.0

        val requiredBps =
            nominalBitrateBps(point.shortEdge, point.fps)
                .coerceAtMost(profile.maxVideoBitrateBps.toDouble())
        val bweRatio =
            filteredBweBps
                ?.takeIf { requiredBps > 0.0 }
                ?.div(requiredBps)

        val bandwidthLimited =
            outbound.qualityLimitationReason
                .equals("bandwidth", ignoreCase = true)
        val senderUnder =
            senderRatio?.let { it < 0.88 } == true

        val networkPressure =
            (
                bandwidthLimited &&
                    (
                        senderUnder ||
                            sendResidenceMs?.let { it >= 60.0 } == true ||
                            bweRatio?.let { it < 1.05 } == true
                        )
                ) ||
                (
                    bweRatio?.let { it < 0.82 } == true &&
                        (
                            senderUnder ||
                                sendResidenceMs?.let { it >= 35.0 } == true
                            )
                    ) ||
                loss >= 0.05 ||
                (
                    (outbound.roundTripTimeMs ?: 0) >= 350 &&
                        (
                            loss >= 0.025 ||
                                sendResidenceMs?.let { it >= 35.0 } == true
                            )
                    )

        val encodePressure =
            encodeMs?.let {
                it >= frameMs * 0.85 &&
                    (
                        senderUnder ||
                            sender.fps < point.fps * 0.88
                        )
            } == true
        val decodePressure =
            received != null &&
                decodeMs?.let {
                    it >= frameMs * 0.85 &&
                        receiverRatio?.let { ratio -> ratio < 0.88 } == true
                } == true
        val devicePressure =
            outbound.qualityLimitationReason
                .equals("cpu", ignoreCase = true) ||
                encodePressure

        val receiverPressure =
            decodePressure ||
                playoutMs?.let { it >= 90.0 } == true ||
                glassRatio?.let { it < 0.82 } == true ||
                renderGapMs?.let {
                    it >= maxOf(100.0, frameMs * 5.0)
                } == true

        val pressure =
            when {
                networkPressure && (devicePressure || receiverPressure) ->
                    PressureKind.MIXED
                devicePressure && receiverPressure ->
                    PressureKind.MIXED
                networkPressure -> PressureKind.NETWORK
                devicePressure -> PressureKind.DEVICE
                receiverPressure -> PressureKind.RECEIVER
                else -> PressureKind.NONE
            }

        val severe =
            bweRatio?.let { it < 0.60 } == true ||
                loss >= 0.12 ||
                sendResidenceMs?.let { it >= 180.0 } == true ||
                playoutMs?.let { it >= 180.0 } == true ||
                (
                    encodeMs?.let { it >= frameMs * 1.20 } == true &&
                        sender.fps < point.fps * 0.65
                    ) ||
                (
                    decodeMs?.let { it >= frameMs * 1.20 } == true &&
                        received?.fps?.let { it < point.fps * 0.65 } == true
                    ) ||
                glassRatio?.let { it < 0.55 } == true ||
                renderGapMs?.let { it >= 250.0 } == true

        if (pressure != PressureKind.NONE) {
            goodWindows = 0
            badWindows = (badWindows + 1).coerceAtMost(3)
            lastPressure = pressure

            if (
                nowMs - lastChangeAtMs >= 2500L &&
                (severe || badWindows >= 3)
            ) {
                val steps = if (severe) 2 else 1
                if (
                    stepDown(
                        profile,
                        deviceFpsLimit,
                        displayRefreshRateHz,
                        steps
                    )
                ) {
                    lastChangeAtMs = nowMs
                    recoveryBlockedUntilMs = nowMs + 8000L
                    badWindows = 0
                    goodWindows = 0
                    lastDecision =
                        pressure.name.lowercase() +
                            if (severe) "-relief-severe" else "-relief"
                    return true
                }
            }
            return false
        }

        badWindows = 0
        lastPressure = PressureKind.NONE

        val senderClean =
            senderRatio?.let { it >= 0.92 } != false &&
                encodeMs?.let { it <= frameMs * 0.65 } != false &&
                sendResidenceMs?.let { it <= 22.0 } != false
        val receiverClean =
            received?.let {
                receiverRatio?.let { ratio -> ratio >= 0.92 } != false &&
                    decodeMs?.let { it <= frameMs * 0.65 } != false &&
                    playoutMs?.let { it <= 50.0 } != false &&
                    glassRatio?.let { it >= 0.92 } != false &&
                    renderGapMs?.let {
                        it <= maxOf(55.0, frameMs * 3.0)
                    } != false
            } ?: true
        val networkClean =
            loss < 0.025 &&
                bweRatio?.let { it >= 1.18 } != false

        val completeClean =
            producerMoving &&
                sender.frames >= 5 &&
                senderClean &&
                receiverClean &&
                networkClean

        goodWindows =
            if (completeClean) {
                (goodWindows + 1).coerceAtMost(8)
            } else {
                0
            }

        if (
            goodWindows >= 8 &&
            nowMs >= recoveryBlockedUntilMs &&
            nowMs - lastChangeAtMs >= 8000L &&
            stepUp(profile, deviceFpsLimit, displayRefreshRateHz)
        ) {
            lastChangeAtMs = nowMs
            goodWindows = 0
            lastDecision = "stable-recovery"
            return true
        }

        return false
    }

    fun effectiveProfile(
        profile: CaptureProfile,
        deviceFpsLimit: Int,
        displayRefreshRateHz: Double?
    ): CaptureProfile {
        val point =
            operatingPoint(profile, deviceFpsLimit, displayRefreshRateHz)
        val nativeShort =
            minOf(profile.captureWidthPx, profile.captureHeightPx)
                .coerceAtLeast(2)
        val desiredShort =
            minOf(nativeShort, point.shortEdge)
                .coerceAtLeast(2)

        val scale = desiredShort.toDouble() / nativeShort.toDouble()

        fun even(value: Int): Int {
            val bounded = value.coerceAtLeast(2)
            return if (bounded % 2 == 0) bounded else bounded - 1
        }

        return profile.copy(
            captureWidthPx =
                even((profile.captureWidthPx * scale).roundToInt()),
            captureHeightPx =
                even((profile.captureHeightPx * scale).roundToInt()),
            fps = point.fps
        )
    }

    fun bitrateCeiling(
        profile: CaptureProfile,
        deviceFpsLimit: Int,
        displayRefreshRateHz: Double?
    ): Int =
        operatingPoint(
            profile,
            deviceFpsLimit,
            displayRefreshRateHz
        ).bitrateCeilingBps

    fun resetEvidence() {
        badWindows = 0
        goodWindows = 0
        filteredBweBps = null
        lastPressure = PressureKind.NONE
        lastObservedAtMs = Long.MIN_VALUE / 2
    }

    fun debugSummary(
        profile: CaptureProfile,
        deviceFpsLimit: Int,
        displayRefreshRateHz: Double?,
        nowMs: Long
    ): String {
        val point =
            operatingPoint(profile, deviceFpsLimit, displayRefreshRateHz)
        val age =
            if (lastChangeAtMs <= Long.MIN_VALUE / 4) {
                "none"
            } else {
                (nowMs - lastChangeAtMs)
                    .coerceAtLeast(0L)
                    .toString() + "ms"
            }
        val bwe =
            filteredBweBps
                ?.div(1000.0)
                ?.roundToInt()
                ?.toString()
                ?.plus("kbps")
                ?: "-"

        return "master=L" + level +
            " " + point.shortEdge + "px@" + point.fps + "fps" +
            " max=" + (point.bitrateCeilingBps / 1000) + "kbps" +
            " bwe=" + bwe +
            " pressure=" + lastPressure.name.lowercase() +
            " bad=" + badWindows + "/3" +
            " good=" + goodWindows + "/8" +
            " decision=" + lastDecision +
            " changeAgo=" + age
    }

    private fun operatingPoint(
        profile: CaptureProfile,
        deviceFpsLimit: Int,
        displayRefreshRateHz: Double?
    ): OperatingPoint {
        val nativeShort =
            minOf(profile.captureWidthPx, profile.captureHeightPx)
                .coerceAtLeast(2)
        val cadenceLimit =
            minOf(
                maxFps,
                profile.motionFps.coerceAtLeast(1),
                deviceFpsLimit.coerceAtLeast(1)
            )
        val high =
            displayMatchedFps(cadenceLimit, displayRefreshRateHz)
        val base =
            displayMatchedFps(minOf(30, cadenceLimit), displayRefreshRateHz)
        val low =
            displayMatchedFps(minOf(24, cadenceLimit), displayRefreshRateHz)

        val shortEdge =
            when (level) {
                0 -> nativeShort
                1 -> minOf(nativeShort, 720)
                2, 3 -> minOf(nativeShort, 540)
                4 -> minOf(nativeShort, 360)
                else -> minOf(nativeShort, 240)
            }
        val fps =
            when (level) {
                0, 1, 2 -> high
                3, 4 -> base
                else -> low
            }.coerceAtLeast(1)

        val ceiling =
            (nominalBitrateBps(shortEdge, fps) * 1.12)
                .roundToInt()
                .coerceIn(250_000, profile.maxVideoBitrateBps)

        return OperatingPoint(level, shortEdge, fps, ceiling)
    }

    private fun stepDown(
        profile: CaptureProfile,
        deviceFpsLimit: Int,
        displayRefreshRateHz: Double?,
        steps: Int
    ): Boolean {
        var moved = false
        repeat(steps.coerceAtLeast(1)) {
            val before =
                operatingPoint(profile, deviceFpsLimit, displayRefreshRateHz)
            var candidate = level + 1
            var found = false
            while (candidate <= 5) {
                val old = level
                level = candidate
                val next =
                    operatingPoint(profile, deviceFpsLimit, displayRefreshRateHz)
                if (
                    next.shortEdge != before.shortEdge ||
                    next.fps != before.fps ||
                    next.bitrateCeilingBps != before.bitrateCeilingBps
                ) {
                    moved = true
                    found = true
                    break
                }
                level = old
                candidate += 1
            }
            if (!found) return@repeat
        }
        return moved
    }

    private fun stepUp(
        profile: CaptureProfile,
        deviceFpsLimit: Int,
        displayRefreshRateHz: Double?
    ): Boolean {
        if (level <= 0) return false

        val before =
            operatingPoint(profile, deviceFpsLimit, displayRefreshRateHz)
        var candidate = level - 1
        while (candidate >= 0) {
            val old = level
            level = candidate
            val next =
                operatingPoint(profile, deviceFpsLimit, displayRefreshRateHz)
            if (
                next.shortEdge != before.shortEdge ||
                next.fps != before.fps ||
                next.bitrateCeilingBps != before.bitrateCeilingBps
            ) {
                return true
            }
            level = old
            candidate -= 1
        }
        return false
    }

    private fun displayMatchedFps(
        limit: Int,
        refreshRateHz: Double?
    ): Int {
        val bounded = limit.coerceIn(1, maxFps)
        if (bounded < 15) return bounded

        val rungs =
            intArrayOf(60, 50, 48, 45, 40, 36, 30, 25, 24, 20, 18, 15)

        val refresh =
            refreshRateHz
                ?.takeIf { it.isFinite() && it >= 15.0 }

        if (refresh != null) {
            rungs.firstOrNull { fps ->
                fps <= bounded &&
                    run {
                        val ratio = refresh / fps.toDouble()
                        val nearest = ratio.roundToInt()
                        nearest >= 1 &&
                            abs(ratio - nearest.toDouble()) <= 0.06
                    }
            }?.let { return it }
        }

        return rungs.firstOrNull { it <= bounded } ?: bounded
    }

    private fun nominalBitrateBps(
        shortEdge: Int,
        fps: Int
    ): Double {
        val baseline30 =
            when {
                shortEdge <= 240 -> 500_000.0
                shortEdge <= 360 -> 900_000.0
                shortEdge <= 540 -> 1_800_000.0
                shortEdge <= 720 -> 3_200_000.0
                shortEdge <= 900 -> 4_200_000.0
                else -> 5_000_000.0
            }
        return baseline30 *
            fps.coerceIn(1, maxFps).toDouble() /
            30.0
    }
}
