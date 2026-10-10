package com.aaris.remoteassist.webrtc

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.floor

/**
 * Device-local realtime encoder throughput guard.
 *
 * Hardware codec presence alone does not prove that a vendor MediaCodec can
 * sustain the current screen geometry at 45/60 fps. Query Android's published
 * performance guarantees (API 29+) or measured achievable frame-rate range
 * (API 23+) once per geometry, then use the result only as an upper bound.
 *
 * Missing/vendor-incomplete metadata is deliberately treated as "unknown":
 * live WebRTC telemetry remains authoritative and no capability is invented.
 */
internal class ScreenEncoderPerformance private constructor(
    private val capabilities: List<EncoderCapability>
) {
    private data class EncoderCapability(
        val implementationName: String,
        val video: MediaCodecInfo.VideoCapabilities
    )

    /*
     * The active WebRTC encoder is one concrete MediaCodec component. Cache the
     * capability result by that component as well as geometry; otherwise a fast
     * secondary H264/VP8 encoder can accidentally lend its 60 fps guarantee to
     * the slower component WebRTC actually selected.
     *
     * A null implementation scope is the startup/unknown fallback and preserves
     * the previous "best available hardware component" behavior until getStats
     * reports encoderImplementation.
     */
    private data class LimitKey(
        val width: Int,
        val height: Int,
        val implementationName: String?
    )

    private val knownLimits = ConcurrentHashMap<LimitKey, Int>()
    private val unknownSizes = ConcurrentHashMap.newKeySet<LimitKey>()

    fun maxFps(
        width: Int,
        height: Int,
        implementationName: String? = null
    ): Int? {
        val safeWidth = width.coerceAtLeast(2)
        val safeHeight = height.coerceAtLeast(2)

        val exactImplementation =
            capabilities.firstOrNull {
                implementationMatches(
                    candidateName = it.implementationName,
                    activeName = implementationName
                )
            }

        val scopedCapabilities =
            if (exactImplementation != null) {
                listOf(exactImplementation)
            } else {
                capabilities
            }
        val scopeName =
            exactImplementation
                ?.implementationName
                ?.lowercase()
        val key =
            LimitKey(
                width = safeWidth,
                height = safeHeight,
                implementationName = scopeName
            )

        knownLimits[key]?.let { return it }
        if (unknownSizes.contains(key)) return null

        val measured =
            scopedCapabilities
                .mapNotNull {
                    realtimeLimit(
                        it.video,
                        safeWidth,
                        safeHeight
                    )
                }
                .maxOrNull()

        if (measured == null) {
            unknownSizes += key
        } else {
            knownLimits[key] = measured
        }
        return measured
    }

    private fun realtimeLimit(
        video: MediaCodecInfo.VideoCapabilities,
        width: Int,
        height: Int
    ): Int? {
        if (!runCatching { video.isSizeSupported(width, height) }.getOrDefault(false)) {
            return null
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val points =
                runCatching { video.supportedPerformancePoints }
                    .getOrNull()
            if (!points.isNullOrEmpty()) {
                val guaranteed =
                    CADENCE_STEPS.firstOrNull { fps ->
                        val requested =
                            MediaCodecInfo.VideoCapabilities.PerformancePoint(
                                width,
                                height,
                                fps
                            )
                        points.any { point ->
                            runCatching { point.covers(requested) }
                                .getOrDefault(false)
                        }
                    }
                /*
                 * A non-empty performance-point table is an explicit hardware
                 * guarantee. If it contains no >=15 fps point for this size,
                 * keep the session at the realtime safety floor rather than
                 * repeatedly probing high cadence that the codec never promised.
                 */
                return guaranteed ?: MIN_REALTIME_FPS
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val upper =
                runCatching {
                    video.getAchievableFrameRatesFor(width, height)
                        ?.upper
                }.getOrNull()
            cadenceAtOrBelow(upper)?.let { return it }
        }

        return null
    }

    companion object {
        private const val H264_MIME = "video/avc"
        private const val VP8_MIME = "video/x-vnd.on2.vp8"
        private const val MIN_REALTIME_FPS = 15

        /*
         * These are source ceilings, not a display pacing ladder. The renderer
         * still chooses refresh-compatible steps. Keeping moderate rungs here
         * prevents a noisy 59.x vendor estimate from being treated as 60 fps.
         */
        private val CADENCE_STEPS =
            intArrayOf(60, 58, 55, 50, 45, 40, 36, 33, 30, 24, 20, 15)

        fun probe(preferredCodec: String): ScreenEncoderPerformance {
            val mime =
                when {
                    preferredCodec.equals("H264", ignoreCase = true) ->
                        H264_MIME
                    preferredCodec.equals("VP8", ignoreCase = true) ->
                        VP8_MIME
                    else ->
                        return ScreenEncoderPerformance(emptyList())
                }

            val codecInfos =
                runCatching {
                    MediaCodecList(MediaCodecList.REGULAR_CODECS)
                        .codecInfos
                        .asList()
                }.getOrDefault(emptyList())

            val videoCapabilities =
                codecInfos.mapNotNull { info ->
                    if (!info.isEncoder || !isRealtimeHardwareCodec(info)) {
                        return@mapNotNull null
                    }
                    if (
                        info.supportedTypes.none {
                            it.equals(mime, ignoreCase = true)
                        }
                    ) {
                        return@mapNotNull null
                    }

                    runCatching {
                        EncoderCapability(
                            implementationName = info.name,
                            video =
                                info.getCapabilitiesForType(mime)
                                    .videoCapabilities
                        )
                    }.getOrNull()
                }

            return ScreenEncoderPerformance(videoCapabilities)
        }

        internal fun cadenceAtOrBelow(
            reportedMaxFps: Double?
        ): Int? {
            val value =
                reportedMaxFps
                    ?.takeIf { it.isFinite() && it > 0.0 }
                    ?: return null
            val whole = floor(value + 1e-6).toInt().coerceAtLeast(1)
            return CADENCE_STEPS.firstOrNull { it <= whole }
                ?: whole
        }

        private fun isRealtimeHardwareCodec(
            info: MediaCodecInfo
        ): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                return info.isHardwareAccelerated
            }

            /*
             * API 26-28 lacks the hardware-accelerated flag. Exclude the
             * canonical Android/Google software components; unknown vendor
             * components remain eligible and live WebRTC telemetry still
             * provides the final safety net.
             */
            val name = info.name.lowercase()
            return SOFTWARE_CODEC_MARKERS.none(name::contains)
        }

        internal fun implementationMatches(
            candidateName: String,
            activeName: String?
        ): Boolean {
            val normalized =
                activeName
                    ?.trim()
                    ?.takeIf(String::isNotBlank)
                    ?: return false
            return candidateName.equals(
                normalized,
                ignoreCase = true
            )
        }

        private val SOFTWARE_CODEC_MARKERS =
            arrayOf(
                "omx.google.",
                "c2.android.",
                "c2.google.",
                "software",
                "sw.",
                "ffmpeg"
            )
    }
}
