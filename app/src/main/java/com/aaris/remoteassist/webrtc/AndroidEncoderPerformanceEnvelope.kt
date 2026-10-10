package com.aaris.remoteassist.webrtc

import android.annotation.TargetApi
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build

/**
 * Manufacturer-declared realtime envelope for the exact Android MediaCodec that
 * libwebrtc reports as the active outbound encoder.
 *
 * This is deliberately advisory and fail-open:
 * - API < 29: no performance-point API -> no cap.
 * - unknown implementation name: no cap.
 * - missing/empty vendor performance metadata: no cap.
 * - known component + positive performance points: cap to the highest cadence
 *   that the component explicitly guarantees for the requested geometry.
 *
 * Runtime WebRTC telemetry remains authoritative and may still lower cadence or
 * pixels further. This class never selects a codec and never touches MediaCodec.
 */
internal class AndroidEncoderPerformanceEnvelope private constructor(
    private val records: List<Record>
) {
    private data class Record(
        val componentNames: Set<String>,
        val mimeType: String,
        val covers: (width: Int, height: Int, fps: Int) -> Boolean
    )

    fun guaranteedFpsCeiling(
        implementation: String?,
        codec: String?,
        width: Int,
        height: Int,
        maximumFps: Int
    ): Int? {
        if (
            implementation.isNullOrBlank() ||
            width <= 0 ||
            height <= 0 ||
            maximumFps <= 0
        ) {
            return null
        }

        val mime = mimeFor(codec) ?: return null
        val component = implementation.trim().lowercase()
        val record =
            records.firstOrNull {
                it.mimeType == mime &&
                    component in it.componentNames
            } ?: return null

        return EncoderPerformancePolicy.highestGuaranteedFps(
            maximumFps = maximumFps
        ) { fps ->
            record.covers(width, height, fps)
        }
    }

    companion object {
        fun create(): AndroidEncoderPerformanceEnvelope {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                return AndroidEncoderPerformanceEnvelope(emptyList())
            }
            return createApi29()
        }

        @TargetApi(Build.VERSION_CODES.Q)
        private fun createApi29(): AndroidEncoderPerformanceEnvelope {
            val records =
                runCatching {
                    MediaCodecList(MediaCodecList.REGULAR_CODECS)
                        .codecInfos
                        .asSequence()
                        .filter { it.isEncoder }
                        .filter { it.isHardwareAccelerated }
                        .flatMap { info ->
                            val names =
                                buildSet {
                                    add(info.name.lowercase())
                                    runCatching {
                                        add(info.canonicalName.lowercase())
                                    }
                                }
                            info.supportedTypes
                                .asSequence()
                                .map(String::lowercase)
                                .filter {
                                    it == MediaFormat.MIMETYPE_VIDEO_AVC ||
                                        it == MediaFormat.MIMETYPE_VIDEO_VP8
                                }
                                .mapNotNull { mime ->
                                    val points =
                                        runCatching {
                                            info.getCapabilitiesForType(mime)
                                                .videoCapabilities
                                                .supportedPerformancePoints
                                                ?.toList()
                                        }.getOrNull()
                                    if (points.isNullOrEmpty()) {
                                        null
                                    } else {
                                        Record(
                                            componentNames = names,
                                            mimeType = mime,
                                            covers = { width, height, fps ->
                                                val required =
                                                    MediaCodecInfo.VideoCapabilities
                                                        .PerformancePoint(
                                                            width,
                                                            height,
                                                            fps
                                                        )
                                                points.any { point ->
                                                    point.covers(required)
                                                }
                                            }
                                        )
                                    }
                                }
                        }
                        .toList()
                }.getOrDefault(emptyList())

            return AndroidEncoderPerformanceEnvelope(records)
        }

        private fun mimeFor(codec: String?): String? {
            val value = codec?.trim()?.uppercase().orEmpty()
            return when {
                "H264" in value || "AVC" in value ->
                    MediaFormat.MIMETYPE_VIDEO_AVC
                "VP8" in value ->
                    MediaFormat.MIMETYPE_VIDEO_VP8
                else -> null
            }
        }
    }
}
