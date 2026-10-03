package com.aaris.remoteassist.webrtc

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import com.aaris.remoteassist.capture.CaptureVideoContract
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack

/**
 * Compatibility screen transport used only while primary RTP video is black or
 * stalled.
 *
 * Mixed-version safety is preserved: until the controller explicitly advertises
 * delta support this behaves exactly like the legacy low-FPS JPEG stream. A
 * v1.8.39+ controller switches the same lane into an adaptive mode: periodic
 * full JPEG anchors plus atomic tile/scroll deltas between anchors. The host,
 * not the controller, decides what changed by comparing raw capture luma.
 */
class FallbackScreenStreamer(
    private val track: VideoTrack,
    private val sendPacket: (ByteArray) -> Boolean,
    private val onDiagnostic: (String) -> Unit
) : AutoCloseable {
    private data class ReferenceFrame(
        val frameId: Long,
        val width: Int,
        val height: Int,
        val rotation: Int,
        val luma: ByteArray
    )

    private val enabled = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val encoding = AtomicBoolean(false)
    private val deltaCapable = AtomicBoolean(false)
    private val interactionActive = AtomicBoolean(false)
    private val lastFrameAtMs = AtomicLong(0L)
    private val adaptiveIntervalMs = AtomicLong(ADAPTIVE_INITIAL_INTERVAL_MS)
    private val frameSequence = AtomicLong(0L)
    private val firstDeltaReported = AtomicBoolean(false)
    private val worker =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(
                runnable,
                "AarisFallbackVideo"
            ).apply {
                priority = Thread.NORM_PRIORITY - 1
            }
        }

    @Volatile
    private var referenceFrame: ReferenceFrame? = null

    @Volatile
    private var lastKeyframeAtMs = 0L

    private val sink = VideoSink { frame ->
        if (closed.get() || !enabled.get()) {
            return@VideoSink
        }

        val now = monotonicNowMs()
        val interval = currentFrameIntervalMs()
        val previous = lastFrameAtMs.get()
        if (previous != 0L && now - previous < interval) {
            return@VideoSink
        }
        if (!lastFrameAtMs.compareAndSet(previous, now)) {
            return@VideoSink
        }
        if (!encoding.compareAndSet(false, true)) {
            return@VideoSink
        }

        frame.retain()
        worker.execute {
            try {
                val sent = encodeAndSend(frame)
                if (deltaCapable.get()) {
                    adjustCadence(sent)
                }
            } finally {
                frame.release()
                encoding.set(false)
            }
        }
    }

    init {
        track.addSink(sink)
    }

    fun setDeltaCapable(capable: Boolean) {
        val changed = deltaCapable.getAndSet(capable) != capable
        if (!changed) return

        referenceFrame = null
        lastKeyframeAtMs = 0L
        adaptiveIntervalMs.set(ADAPTIVE_INITIAL_INTERVAL_MS)
        firstDeltaReported.set(false)
        onDiagnostic(
            if (capable) {
                "Compatibility transport upgraded • adaptive delta screen enabled"
            } else {
                "Compatibility transport using legacy JPEG mode"
            }
        )
    }

    fun setInteractionActive(active: Boolean) {
        interactionActive.set(active)
    }

    fun enable() {
        if (closed.get() || !enabled.compareAndSet(false, true)) {
            return
        }

        lastFrameAtMs.set(0L)
        referenceFrame = null
        lastKeyframeAtMs = 0L
        adaptiveIntervalMs.set(ADAPTIVE_INITIAL_INTERVAL_MS)
        firstDeltaReported.set(false)

        onDiagnostic(
            if (deltaCapable.get()) {
                "Compatibility screen stream ENABLED • adaptive delta mode"
            } else {
                "Compatibility screen stream ENABLED over fallback DataChannel"
            }
        )
    }

    fun disable() {
        if (enabled.compareAndSet(true, false)) {
            referenceFrame = null
            lastKeyframeAtMs = 0L
            onDiagnostic("Compatibility screen stream disabled")
        }
    }

    private fun currentFrameIntervalMs(): Long {
        if (!deltaCapable.get()) return LEGACY_FRAME_INTERVAL_MS

        val adaptive = adaptiveIntervalMs.get()
        return if (interactionActive.get()) {
            adaptive.coerceIn(
                ADAPTIVE_MIN_INTERVAL_MS,
                ADAPTIVE_MAX_INTERVAL_MS
            )
        } else {
            maxOf(
                ADAPTIVE_IDLE_MIN_INTERVAL_MS,
                adaptive
            ).coerceAtMost(ADAPTIVE_MAX_INTERVAL_MS)
        }
    }

    private fun adjustCadence(sent: Boolean) {
        while (true) {
            val previous = adaptiveIntervalMs.get()
            val next =
                if (sent) {
                    (previous - ADAPTIVE_SUCCESS_STEP_MS)
                        .coerceAtLeast(ADAPTIVE_MIN_INTERVAL_MS)
                } else {
                    (previous * 3L / 2L + ADAPTIVE_FAILURE_PENALTY_MS)
                        .coerceAtMost(ADAPTIVE_MAX_INTERVAL_MS)
                }
            if (adaptiveIntervalMs.compareAndSet(previous, next)) {
                return
            }
        }
    }

    private fun encodeAndSend(frame: VideoFrame): Boolean {
        if (closed.get() || !enabled.get()) return false

        val i420 = frame.buffer.toI420() ?: return false
        try {
            val width = i420.width
            val height = i420.height
            if (
                width <= 1 ||
                height <= 1 ||
                width > MAX_DIMENSION ||
                height > MAX_DIMENSION
            ) {
                return false
            }

            return if (deltaCapable.get()) {
                encodeAdaptive(
                    i420 = i420,
                    width = width,
                    height = height,
                    rotation = normalizeRotation(frame.rotation)
                )
            } else {
                sendLegacyKeyframe(
                    i420 = i420,
                    width = width,
                    height = height,
                    rotation = normalizeRotation(frame.rotation),
                    adaptiveAnchor = false,
                    packedLuma = null
                )
            }
        } finally {
            i420.release()
        }
    }

    private fun encodeAdaptive(
        i420: VideoFrame.I420Buffer,
        width: Int,
        height: Int,
        rotation: Int
    ): Boolean {
        val packedLuma = copyLuma(i420)
        val reference = referenceFrame
        val now = monotonicNowMs()
        val keyframeInterval =
            if (interactionActive.get()) {
                INTERACTIVE_KEYFRAME_INTERVAL_MS
            } else {
                IDLE_KEYFRAME_INTERVAL_MS
            }

        if (
            reference == null ||
            reference.width != width ||
            reference.height != height ||
            reference.rotation != rotation ||
            lastKeyframeAtMs == 0L ||
            now - lastKeyframeAtMs >= keyframeInterval
        ) {
            return sendLegacyKeyframe(
                i420 = i420,
                width = width,
                height = height,
                rotation = rotation,
                adaptiveAnchor = true,
                packedLuma = packedLuma
            )
        }

        val plan = runCatching {
            FrameDeltaAnalyzer.analyze(
                previousY = reference.luma,
                currentY = packedLuma,
                width = width,
                height = height
            )
        }.getOrElse {
            return sendLegacyKeyframe(
                i420 = i420,
                width = width,
                height = height,
                rotation = rotation,
                adaptiveAnchor = true,
                packedLuma = packedLuma
            )
        }

        if (plan.regions.isEmpty() && !plan.forceKeyframe) {
            // Do not advance the host reference for pixels that were never sent.
            // This keeps host/controller bases identical across many tiny changes.
            return true
        }

        if (plan.forceKeyframe) {
            return sendLegacyKeyframe(
                i420 = i420,
                width = width,
                height = height,
                rotation = rotation,
                adaptiveAnchor = true,
                packedLuma = packedLuma
            )
        }

        val nv21 = toNv21(i420)
        val image =
            YuvImage(
                nv21,
                ImageFormat.NV21,
                width,
                height,
                null
            )
        val patches = ArrayList<FallbackDeltaPatch>(plan.regions.size)
        var jpegBytes = 0

        for (region in plan.regions) {
            val rect =
                Rect(
                    region.x,
                    region.y,
                    region.x + region.width,
                    region.y + region.height
                )
            val jpeg =
                compressRegionWithinBudget(
                    image = image,
                    rect = rect,
                    maxBytes = MAX_PATCH_JPEG_BYTES
                ) ?: return sendLegacyKeyframe(
                    i420 = i420,
                    width = width,
                    height = height,
                    rotation = rotation,
                    adaptiveAnchor = true,
                    packedLuma = packedLuma
                )

            jpegBytes += jpeg.size
            if (jpegBytes > MAX_DELTA_JPEG_BYTES) {
                return sendLegacyKeyframe(
                    i420 = i420,
                    width = width,
                    height = height,
                    rotation = rotation,
                    adaptiveAnchor = true,
                    packedLuma = packedLuma
                )
            }

            patches +=
                FallbackDeltaPatch(
                    x = region.x,
                    y = region.y,
                    width = region.width,
                    height = region.height,
                    jpeg = jpeg
                )
        }

        if (patches.isEmpty()) return true

        val id = frameSequence.incrementAndGet()
        val packets = runCatching {
            FallbackDeltaProtocol.encode(
                FallbackDeltaFrame(
                    frameId = id,
                    baseFrameId = reference.frameId,
                    width = width,
                    height = height,
                    rotation = rotation,
                    shiftX = 0,
                    shiftY = plan.shiftY,
                    patches = patches
                )
            )
        }.getOrElse {
            return false
        }

        val allSent = sendPackets(packets)
        if (allSent) {
            referenceFrame =
                ReferenceFrame(
                    frameId = id,
                    width = width,
                    height = height,
                    rotation = rotation,
                    luma = advanceReferenceLuma(
                        previous = reference.luma,
                        current = packedLuma,
                        width = width,
                        height = height,
                        shiftY = plan.shiftY,
                        regions = plan.regions
                    )
                )
            if (firstDeltaReported.compareAndSet(false, true)) {
                onDiagnostic(
                    "Adaptive delta frame sent • patches=" +
                        patches.size +
                        " bytes=" +
                        jpegBytes +
                        " shiftY=" +
                        plan.shiftY
                )
            }
        }
        return allSent
    }

    private fun advanceReferenceLuma(
        previous: ByteArray,
        current: ByteArray,
        width: Int,
        height: Int,
        shiftY: Int,
        regions: List<DeltaRegion>
    ): ByteArray {
        val result = ByteArray(width * height)

        for (y in 0 until height) {
            val sourceY = y - shiftY
            if (sourceY !in 0 until height) continue
            previous.copyInto(
                destination = result,
                destinationOffset = y * width,
                startIndex = sourceY * width,
                endIndex = (sourceY + 1) * width
            )
        }

        regions.forEach { region ->
            for (y in region.y until region.y + region.height) {
                val start = y * width + region.x
                current.copyInto(
                    destination = result,
                    destinationOffset = start,
                    startIndex = start,
                    endIndex = start + region.width
                )
            }
        }
        return result
    }

    private fun sendLegacyKeyframe(
        i420: VideoFrame.I420Buffer,
        width: Int,
        height: Int,
        rotation: Int,
        adaptiveAnchor: Boolean,
        packedLuma: ByteArray?
    ): Boolean {
        val nv21 = toNv21(i420)
        val jpeg =
            compressFullFrameWithinBudget(
                nv21 = nv21,
                width = width,
                height = height,
                adaptiveAnchor = adaptiveAnchor
            ) ?: return false

        val id = frameSequence.incrementAndGet()
        val packets =
            FallbackVideoProtocol.encodeFrame(
                frameId = id,
                width = width,
                height = height,
                rotation = rotation,
                jpeg = jpeg
            )
        val allSent = sendPackets(packets)

        if (allSent) {
            if (adaptiveAnchor) {
                referenceFrame =
                    ReferenceFrame(
                        frameId = id,
                        width = width,
                        height = height,
                        rotation = rotation,
                        luma = packedLuma ?: copyLuma(i420)
                    )
                lastKeyframeAtMs = monotonicNowMs()
            }
            if (id == 1L) {
                onDiagnostic(
                    "First compatibility JPEG frame sent (" +
                        jpeg.size +
                        " bytes)"
                )
            }
        }

        return allSent
    }

    private fun sendPackets(packets: List<ByteArray>): Boolean {
        for (packet in packets) {
            if (!sendPacket(packet)) {
                return false
            }
        }
        return true
    }

    private fun compressFullFrameWithinBudget(
        nv21: ByteArray,
        width: Int,
        height: Int,
        adaptiveAnchor: Boolean
    ): ByteArray? {
        val image =
            YuvImage(
                nv21,
                ImageFormat.NV21,
                width,
                height,
                null
            )
        val rect = Rect(0, 0, width, height)
        val ladder =
            if (adaptiveAnchor) {
                ADAPTIVE_KEYFRAME_QUALITY_LADDER
            } else {
                LEGACY_JPEG_QUALITY_LADDER
            }
        val byteLimit =
            if (adaptiveAnchor) {
                MAX_ADAPTIVE_KEYFRAME_BYTES
            } else {
                MAX_LEGACY_JPEG_BYTES
            }

        return compressWithLadder(
            image = image,
            rect = rect,
            qualities = ladder,
            maxBytes = byteLimit,
            initialCapacity =
                minOf(
                    MAX_JPEG_ESTIMATE_BYTES,
                    width * height / 2
                )
        )
    }

    private fun compressRegionWithinBudget(
        image: YuvImage,
        rect: Rect,
        maxBytes: Int
    ): ByteArray? =
        compressWithLadder(
            image = image,
            rect = rect,
            qualities = PATCH_JPEG_QUALITY_LADDER,
            maxBytes = maxBytes,
            initialCapacity =
                minOf(
                    MAX_PATCH_ESTIMATE_BYTES,
                    rect.width() * rect.height() / 2
                ).coerceAtLeast(4_096)
        )

    private fun compressWithLadder(
        image: YuvImage,
        rect: Rect,
        qualities: IntArray,
        maxBytes: Int,
        initialCapacity: Int
    ): ByteArray? {
        for (quality in qualities) {
            val output = ByteArrayOutputStream(initialCapacity)
            if (!image.compressToJpeg(rect, quality, output)) {
                return null
            }
            val jpeg = output.toByteArray()
            if (jpeg.isNotEmpty() && jpeg.size <= maxBytes) {
                return jpeg
            }
        }
        return null
    }

    private fun copyLuma(
        buffer: VideoFrame.I420Buffer
    ): ByteArray {
        val width = buffer.width
        val height = buffer.height
        val result = ByteArray(width * height)
        copyPlane(
            source = buffer.dataY,
            sourceStride = buffer.strideY,
            planeWidth = width,
            planeHeight = height,
            destination = result,
            destinationOffset = 0,
            destinationStride = width
        )
        return result
    }

    private fun toNv21(
        buffer: VideoFrame.I420Buffer
    ): ByteArray {
        val width = buffer.width
        val height = buffer.height
        val chromaWidth = (width + 1) / 2
        val chromaHeight = (height + 1) / 2
        val ySize = width * height
        val result =
            ByteArray(
                ySize +
                    (chromaWidth * chromaHeight * 2)
            )

        copyPlane(
            source = buffer.dataY,
            sourceStride = buffer.strideY,
            planeWidth = width,
            planeHeight = height,
            destination = result,
            destinationOffset = 0,
            destinationStride = width
        )

        val u = buffer.dataU.duplicate()
        val v = buffer.dataV.duplicate()
        var out = ySize

        for (row in 0 until chromaHeight) {
            val uRow = row * buffer.strideU
            val vRow = row * buffer.strideV
            for (column in 0 until chromaWidth) {
                result[out++] = v.get(vRow + column)
                result[out++] = u.get(uRow + column)
            }
        }

        return result
    }

    private fun copyPlane(
        source: ByteBuffer,
        sourceStride: Int,
        planeWidth: Int,
        planeHeight: Int,
        destination: ByteArray,
        destinationOffset: Int,
        destinationStride: Int
    ) {
        val src = source.duplicate()
        var dstRow = destinationOffset

        for (row in 0 until planeHeight) {
            val srcRow = row * sourceStride
            for (column in 0 until planeWidth) {
                destination[dstRow + column] = src.get(srcRow + column)
            }
            dstRow += destinationStride
        }
    }

    private fun normalizeRotation(value: Int): Int =
        when (((value % 360) + 360) % 360) {
            in 45..134 -> 90
            in 135..224 -> 180
            in 225..314 -> 270
            else -> 0
        }

    private fun monotonicNowMs(): Long =
        System.nanoTime() / 1_000_000L

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        enabled.set(false)
        referenceFrame = null
        runCatching { track.removeSink(sink) }
        worker.shutdownNow()
    }

    companion object {
        private const val MAX_DIMENSION =
            CaptureVideoContract.MAX_FALLBACK_SAFE_LONG_SIDE_PX

        private const val LEGACY_FRAME_INTERVAL_MS = 450L
        private const val ADAPTIVE_INITIAL_INTERVAL_MS = 90L
        private const val ADAPTIVE_MIN_INTERVAL_MS = 45L
        private const val ADAPTIVE_IDLE_MIN_INTERVAL_MS = 120L
        private const val ADAPTIVE_MAX_INTERVAL_MS = 450L
        private const val ADAPTIVE_SUCCESS_STEP_MS = 6L
        private const val ADAPTIVE_FAILURE_PENALTY_MS = 24L

        private const val INTERACTIVE_KEYFRAME_INTERVAL_MS = 3_500L
        private const val IDLE_KEYFRAME_INTERVAL_MS = 6_000L

        private val LEGACY_JPEG_QUALITY_LADDER =
            intArrayOf(62, 50, 38)
        private val ADAPTIVE_KEYFRAME_QUALITY_LADDER =
            intArrayOf(44, 34, 26, 20, 16)
        private val PATCH_JPEG_QUALITY_LADDER =
            intArrayOf(56, 46, 36, 28, 22)

        private const val MAX_LEGACY_JPEG_BYTES = 720_000
        private const val MAX_ADAPTIVE_KEYFRAME_BYTES = 240_000
        private const val MAX_PATCH_JPEG_BYTES = 56_000
        private const val MAX_DELTA_JPEG_BYTES = 56_000
        private const val MAX_JPEG_ESTIMATE_BYTES = 320_000
        private const val MAX_PATCH_ESTIMATE_BYTES = 96_000
    }
}
