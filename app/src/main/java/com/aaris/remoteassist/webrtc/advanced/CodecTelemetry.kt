package com.aaris.remoteassist.webrtc.advanced

import android.os.SystemClock
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference
import org.webrtc.EncodedImage
import org.webrtc.VideoCodecInfo
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoDecoder
import org.webrtc.VideoDecoderFactory
import org.webrtc.VideoDecoderFallback
import org.webrtc.VideoEncoder
import org.webrtc.VideoEncoderFactory
import org.webrtc.VideoEncoderFallback
import org.webrtc.VideoFrame

/** Fixed-size rolling sample ring used for cheap recent percentiles. */
class SampleRing(private val capacity: Int = 128) {
    private val values: DoubleArray
    private var size = 0
    private var head = 0

    init {
        require(capacity > 0)
        values = DoubleArray(capacity)
    }

    @Synchronized
    fun add(value: Double) {
        if (!value.isFinite()) return
        values[head] = value
        head = (head + 1) % capacity
        if (size < capacity) size += 1
    }

    @Synchronized
    fun percentile(p: Double): Double? {
        if (size == 0) return null
        val bounded = p.coerceIn(0.0, 1.0)
        val copy = DoubleArray(size)
        if (size < capacity) {
            values.copyInto(copy, endIndex = size)
        } else {
            // Once wrapped, chronological order is irrelevant for percentile,
            // so copying the full fixed ring is sufficient.
            values.copyInto(copy)
        }
        copy.sort()
        val index = ((size - 1) * bounded).toInt().coerceIn(0, size - 1)
        return copy[index]
    }

    @Synchronized
    fun count(): Int = size
}

class EncoderTelemetry {
    data class Snapshot(
        val samples: Int,
        val encodeP50Ms: Double?,
        val encodeP95Ms: Double?,
        val frameBytesP95: Double?,
        val inFlight: Int,
        val lastQp: Int?,
        val vbvDelayMs: Double?,
        val keyFrames: Long,
        val rejected: Long
    )

    private val encodeMs = SampleRing()
    private val frameBytes = SampleRing()
    private val lock = Any()
    private val pendingCaptureNs = LongArray(PENDING_SLOTS)
    private val pendingStartedNs = LongArray(PENDING_SLOTS)
    private var pendingHead = 0

    val bucket = LeakyBucketSendModel()

    @Volatile
    private var lastQp: Int? = null

    @Volatile
    private var keyFrames = 0L

    @Volatile
    private var rejected = 0L

    @Volatile
    private var lastVbvDelayMs: Double? = null

    fun onTargetBitrate(bps: Long) {
        bucket.setTargetBps(SystemClock.elapsedRealtimeNanos(), bps)
    }

    fun onEncodeStart(captureNs: Long) {
        synchronized(lock) {
            pendingCaptureNs[pendingHead] = captureNs
            pendingStartedNs[pendingHead] = SystemClock.elapsedRealtimeNanos()
            pendingHead = (pendingHead + 1) % PENDING_SLOTS
        }
    }

    fun onEncodeRejected(captureNs: Long) {
        rejected += 1
        clearPending(captureNs)
    }

    fun onEncoded(
        captureNs: Long,
        bytes: Int,
        isKey: Boolean,
        qp: Int?
    ) {
        val nowNs = SystemClock.elapsedRealtimeNanos()
        synchronized(lock) {
            for (index in pendingCaptureNs.indices) {
                if (
                    pendingCaptureNs[index] == captureNs &&
                    pendingStartedNs[index] != 0L
                ) {
                    val elapsedMs =
                        (nowNs - pendingStartedNs[index]).coerceAtLeast(0L) /
                            1_000_000.0
                    encodeMs.add(elapsedMs)
                    pendingStartedNs[index] = 0L
                    pendingCaptureNs[index] = 0L
                    break
                }
            }
        }

        frameBytes.add(bytes.coerceAtLeast(0).toDouble())
        if (isKey) keyFrames += 1
        if (qp != null) lastQp = qp
        lastVbvDelayMs = bucket.onFrameEncoded(nowNs, bytes.coerceAtLeast(0))
    }

    fun queueDelayMs(nowNs: Long = SystemClock.elapsedRealtimeNanos()): Double? =
        bucket.queueDelayMs(nowNs)

    fun inFlightFrames(): Int = synchronized(lock) {
        val nowNs = SystemClock.elapsedRealtimeNanos()
        pendingStartedNs.count { started ->
            started != 0L &&
                nowNs >= started &&
                nowNs - started <= STALE_PENDING_NS
        }
    }

    fun snapshot(): Snapshot =
        Snapshot(
            samples = encodeMs.count(),
            encodeP50Ms = encodeMs.percentile(0.50),
            encodeP95Ms = encodeMs.percentile(0.95),
            frameBytesP95 = frameBytes.percentile(0.95),
            inFlight = inFlightFrames(),
            lastQp = lastQp,
            vbvDelayMs = lastVbvDelayMs,
            keyFrames = keyFrames,
            rejected = rejected
        )

    private fun clearPending(captureNs: Long) {
        synchronized(lock) {
            for (index in pendingCaptureNs.indices) {
                if (pendingCaptureNs[index] == captureNs) {
                    pendingCaptureNs[index] = 0L
                    pendingStartedNs[index] = 0L
                    return
                }
            }
        }
    }

    private companion object {
        const val PENDING_SLOTS = 32
        const val STALE_PENDING_NS = 1_000_000_000L
    }
}

class DecoderTelemetry {
    data class Snapshot(
        val samples: Int,
        val decodeP50Ms: Double?,
        val decodeP95Ms: Double?,
        val qpP50: Double?
    )

    private val decodeMs = SampleRing()
    private val qps = SampleRing()

    fun onDecoded(decodeTimeMs: Int?, qp: Int?) {
        if (decodeTimeMs != null && decodeTimeMs >= 0) {
            decodeMs.add(decodeTimeMs.toDouble())
        }
        if (qp != null && qp >= 0) {
            qps.add(qp.toDouble())
        }
    }

    fun snapshot(): Snapshot =
        Snapshot(
            samples = decodeMs.count(),
            decodeP50Ms = decodeMs.percentile(0.50),
            decodeP95Ms = decodeMs.percentile(0.95),
            qpP50 = qps.percentile(0.50)
        )
}

/** Java/hardware encoder wrapper. Native software encoders keep their native path. */
class TelemetryVideoEncoder(
    private val inner: VideoEncoder,
    private val telemetry: EncoderTelemetry
) : VideoEncoder {
    override fun createNative(webrtcEnvRef: Long): Long =
        inner.createNative(webrtcEnvRef)

    override fun isHardwareEncoder(): Boolean = inner.isHardwareEncoder

    override fun initEncode(
        settings: VideoEncoder.Settings,
        callback: VideoEncoder.Callback
    ): VideoCodecStatus =
        inner.initEncode(
            settings,
            VideoEncoder.Callback { frame, info ->
                telemetry.onEncoded(
                    captureNs = frame.captureTimeNs,
                    bytes = frame.buffer.remaining(),
                    isKey =
                        frame.frameType ==
                            EncodedImage.FrameType.VideoFrameKey,
                    qp = frame.qp
                )
                callback.onEncodedFrame(frame, info)
            }
        )

    override fun release(): VideoCodecStatus = inner.release()

    override fun encode(
        frame: VideoFrame,
        info: VideoEncoder.EncodeInfo
    ): VideoCodecStatus {
        telemetry.onEncodeStart(frame.timestampNs)
        val status = inner.encode(frame, info)
        if (status != VideoCodecStatus.OK) {
            telemetry.onEncodeRejected(frame.timestampNs)
        }
        return status
    }

    override fun setRateAllocation(
        allocation: VideoEncoder.BitrateAllocation,
        framerate: Int
    ): VideoCodecStatus {
        telemetry.onTargetBitrate(allocation.sum.toLong())
        return inner.setRateAllocation(allocation, framerate)
    }

    override fun setRates(
        rcParameters: VideoEncoder.RateControlParameters
    ): VideoCodecStatus {
        telemetry.onTargetBitrate(rcParameters.bitrate.sum.toLong())
        return inner.setRates(rcParameters)
    }

    override fun getScalingSettings(): VideoEncoder.ScalingSettings =
        inner.scalingSettings

    override fun getResolutionBitrateLimits(): Array<VideoEncoder.ResolutionBitrateLimits> =
        inner.resolutionBitrateLimits

    override fun getImplementationName(): String = inner.implementationName

    override fun getEncoderInfo(): VideoEncoder.EncoderInfo = inner.encoderInfo
}

/** Java/hardware decoder wrapper. Native software decoders keep their native path. */
class TelemetryVideoDecoder(
    private val inner: VideoDecoder,
    private val telemetry: DecoderTelemetry
) : VideoDecoder {
    override fun createNative(webrtcEnvRef: Long): Long =
        inner.createNative(webrtcEnvRef)

    override fun initDecode(
        settings: VideoDecoder.Settings,
        callback: VideoDecoder.Callback
    ): VideoCodecStatus =
        inner.initDecode(
            settings,
            VideoDecoder.Callback { frame, decodeTimeMs, qp ->
                telemetry.onDecoded(decodeTimeMs, qp)
                callback.onDecodedFrame(frame, decodeTimeMs, qp)
            }
        )

    override fun release(): VideoCodecStatus = inner.release()

    override fun decode(
        frame: EncodedImage,
        info: VideoDecoder.DecodeInfo
    ): VideoCodecStatus = inner.decode(frame, info)

    override fun getImplementationName(): String = inner.implementationName
}

/** Latest per-codec telemetry handles for the single active Aaris media session. */
class CodecTelemetryRegistry {
    private val encoders = ConcurrentHashMap<String, EncoderTelemetry>()
    private val decoders = ConcurrentHashMap<String, DecoderTelemetry>()
    private val latestEncoder = AtomicReference<EncoderTelemetry?>(null)
    private val latestDecoder = AtomicReference<DecoderTelemetry?>(null)

    fun registerEncoder(info: VideoCodecInfo, telemetry: EncoderTelemetry) {
        encoders[normalize(info.name)] = telemetry
        latestEncoder.set(telemetry)
    }

    fun registerDecoder(info: VideoCodecInfo, telemetry: DecoderTelemetry) {
        decoders[normalize(info.name)] = telemetry
        latestDecoder.set(telemetry)
    }

    fun encoder(codec: String?): EncoderTelemetry? =
        codec
            ?.let(::normalize)
            ?.let(encoders::get)
            ?: latestEncoder.get()

    fun decoder(codec: String?): DecoderTelemetry? =
        codec
            ?.let(::normalize)
            ?.let(decoders::get)
            ?: latestDecoder.get()

    fun latestEncoder(): EncoderTelemetry? = latestEncoder.get()

    private fun normalize(value: String): String =
        value.substringAfterLast('/').uppercase()
}

/** Replicates DefaultVideoEncoderFactory ordering while wrapping Java hardware. */
class TelemetryEncoderFactory(
    private val hardware: VideoEncoderFactory,
    private val software: VideoEncoderFactory,
    private val registry: CodecTelemetryRegistry
) : VideoEncoderFactory {
    override fun createEncoder(info: VideoCodecInfo): VideoEncoder? {
        val softwareEncoder = software.createEncoder(info)
        val hardwareEncoder = hardware.createEncoder(info)?.let { raw ->
            val telemetry = EncoderTelemetry()
            registry.registerEncoder(info, telemetry)
            TelemetryVideoEncoder(raw, telemetry)
        }

        return when {
            hardwareEncoder != null && softwareEncoder != null ->
                VideoEncoderFallback(softwareEncoder, hardwareEncoder)
            hardwareEncoder != null -> hardwareEncoder
            else -> softwareEncoder
        }
    }

    override fun getSupportedCodecs(): Array<VideoCodecInfo> {
        val all = LinkedHashSet<VideoCodecInfo>()
        software.supportedCodecs.forEach(all::add)
        hardware.supportedCodecs.forEach(all::add)
        return all.toTypedArray()
    }
}

/**
 * Replicates DefaultVideoDecoderFactory ordering, including platform-software
 * MediaCodec fallback, while wrapping Java decoders for p95 latency telemetry.
 */
class TelemetryDecoderFactory(
    private val hardware: VideoDecoderFactory,
    private val software: VideoDecoderFactory,
    private val platformSoftware: VideoDecoderFactory?,
    private val registry: CodecTelemetryRegistry
) : VideoDecoderFactory {
    override fun createDecoder(info: VideoCodecInfo): VideoDecoder? {
        var softwareDecoder = software.createDecoder(info)
        if (softwareDecoder == null && platformSoftware != null) {
            softwareDecoder = platformSoftware.createDecoder(info)?.let { raw ->
                val telemetry = DecoderTelemetry()
                registry.registerDecoder(info, telemetry)
                TelemetryVideoDecoder(raw, telemetry)
            }
        }

        val hardwareDecoder = hardware.createDecoder(info)?.let { raw ->
            val telemetry = DecoderTelemetry()
            registry.registerDecoder(info, telemetry)
            TelemetryVideoDecoder(raw, telemetry)
        }

        return when {
            hardwareDecoder != null && softwareDecoder != null ->
                VideoDecoderFallback(softwareDecoder, hardwareDecoder)
            hardwareDecoder != null -> hardwareDecoder
            else -> softwareDecoder
        }
    }

    override fun getSupportedCodecs(): Array<VideoCodecInfo> {
        val all = LinkedHashSet<VideoCodecInfo>()
        software.supportedCodecs.forEach(all::add)
        hardware.supportedCodecs.forEach(all::add)
        platformSoftware?.supportedCodecs?.forEach(all::add)
        return all.toTypedArray()
    }
}
